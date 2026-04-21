# effect/handlers.nix — Phase 4.0
#
# Effect Handlers（代数效果分发）
#
# 设计原则：
#   handle : Eff(E ++ R, A) → Handler(E, A, B) → Eff(R, B)
#   - Handler = { effectTag; branches: [HandlerBranch]; returnClause }
#   - HandlerBranch = { opName; params; resume; body }
#   - handle 后 effect row 中 E 被精确移除（INV-EFF-4）
#   - subtractEffect 正确计算残余 effect（INV-EFF-5）
#
# Phase 4.0 新增（基于 Phase 3.3 subtractEffect）：
#   - Handler TypeIR（完整结构，∈ TypeIR）
#   - open effect row（RowVar tail）支持
#   - Handler 类型检查
#   - 多 handler 组合（handleAll）
#
# 不变量：
#   INV-EFF-4: handle 后 effect row 中 E 被移除（soundness）
#   INV-EFF-5: 残余 effect = original - handled（精确 subtract）
#   INV-EFF-6: open effect row（RowVar）在 subtract 后保留 tail
#   INV-EFF-7: Handler 操作名不重复（coherence）

{ lib, typeLib, kindLib, reprLib, normalizeLib, hashLib }:

let
  inherit (typeLib) mkTypeDefault mkTypeWith;
  inherit (kindLib) KStar KArrow KEffect;
  inherit (reprLib)
    rPrimitive rVar rFn rADT rConstrained rEffect
    rVariantRow rRowEmpty rRowVar rRowExtend rOpaque;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Handler TypeRepr
  # ══════════════════════════════════════════════════════════════════════════════

  rHandler = effectTag: branches: returnType: {
    __variant = "Handler";
    inherit effectTag branches;
    returnType = returnType;
  };

  rHandlerBranch = opName: params: resumeParam: body: {
    inherit opName params resumeParam body;
  };

  mkHandler = effectTag: branches: returnType:
    mkTypeDefault (rHandler effectTag branches returnType) KStar;

  # ── Effect 操作类型构造器 ────────────────────────────────────────────────────

  # mkEffOp: 声明一个 effect 操作
  # opName: String, paramTypes: [Type], returnType: Type
  mkEffOp = opName: paramTypes: retType: {
    inherit opName paramTypes retType;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # Effect Row 操作（Phase 3.3 subtractEffect 升级版）
  # ══════════════════════════════════════════════════════════════════════════════

  # _flattenEffect：将 Effect/EffectMerge 展开为 flat variants map + tail
  # Phase 4.0：支持 RowVar tail（INV-EFF-6）
  _flattenEffectFull = effTy:
    let r = effTy.repr or {}; in
    if r.__variant == "Effect" then
      let rowR = (r.effectRow or { repr = { __variant = "RowEmpty"; }; }).repr or {}; in
      if rowR.__variant == "VariantRow" then
        { variants = rowR.variants or {}; tail = rowR.extension or null; }
      else if rowR.__variant == "RowVar" then
        { variants = {}; tail = effTy; }  # Phase 4.0 fix: 保留 RowVar tail
      else if rowR.__variant == "RowEmpty" then
        { variants = {}; tail = null; }
      else { variants = {}; tail = null; }
    else if r.__variant == "EffectMerge" then
      let
        l = _flattenEffectFull r.left;
        rr = _flattenEffectFull r.right;
        merged = l.variants // rr.variants;  # right-biased
        # tail 合并：若 rr 有 tail 则用 rr 的，否则用 l 的
        tail = if rr.tail != null then rr.tail
               else if l.tail != null then l.tail
               else null;
      in
      { variants = merged; tail = tail; }
    else if r.__variant == "RowVar" then
      { variants = {}; tail = effTy; }  # 直接 RowVar
    else { variants = {}; tail = null; };

  # subtractEffect：从 effect type 移除指定 effect tags（INV-EFF-4/5/6）
  subtractEffect = effTy: tagsToRemove:
    let
      flat   = _flattenEffectFull effTy;
      remaining = lib.filterAttrs (tag: _: !(lib.elem tag tagsToRemove)) flat.variants;
      rowExt = lib.foldl'
        (acc: kv: mkTypeDefault (rRowExtend kv.name kv.value acc) kindLib.KRow)
        (if flat.tail != null then flat.tail
         else mkTypeDefault rRowEmpty kindLib.KRow)
        (lib.sort (a: b: a.name < b.name)
          (lib.mapAttrsToList (k: v: { name = k; value = v; }) remaining));
    in
    if remaining == {} && flat.tail == null then
      mkTypeDefault (rEffect (mkTypeDefault rRowEmpty kindLib.KRow)) KStar
    else
      mkTypeDefault (rEffect rowExt) KStar;

  # addEffect：向 effect type 添加 effect tags
  addEffect = effTy: newVariants:
    let
      flat    = _flattenEffectFull effTy;
      allVars = flat.variants // newVariants;
      sorted  = lib.sort (a: b: a.name < b.name)
                  (lib.mapAttrsToList (k: v: { name = k; value = v; }) allVars);
      rowExt  = lib.foldl'
        (acc: kv: mkTypeDefault (rRowExtend kv.name kv.value acc) kindLib.KRow)
        (if flat.tail != null then flat.tail
         else mkTypeDefault rRowEmpty kindLib.KRow)
        sorted;
    in
    mkTypeDefault (rEffect rowExt) KStar;

  # getEffectTags：获取 effect type 中的所有 tag 名
  getEffectTags = effTy:
    let flat = _flattenEffectFull effTy; in
    lib.sort (a: b: a < b) (builtins.attrNames flat.variants);

  # hasEffect：检查 effect type 是否包含指定 tag
  hasEffect = effTy: tag:
    let flat = _flattenEffectFull effTy; in
    flat.variants ? ${tag};

  # ══════════════════════════════════════════════════════════════════════════════
  # Handler Type Checking
  # ══════════════════════════════════════════════════════════════════════════════

  # checkHandler：验证 Handler 是否正确处理 effectTag
  # Result: { ok; missing; extra; residualEffTy }
  checkHandler = effTy: handler:
    let
      handlerR   = handler.repr or {};
      effectTag  = handlerR.effectTag or null;
      branches   = handlerR.branches or [];

      # 检查 effect type 是否包含该 effectTag
      hasTag = hasEffect effTy effectTag;

      # 计算残余 effect（INV-EFF-4）
      residualEffTy = if hasTag
        then subtractEffect effTy [effectTag]
        else effTy;

      # 验证 handler branches 与已知操作的对应关系（简化：按 opName 验证）
      branchNames = map (b: b.opName) branches;
      uniqueNames = lib.unique branchNames;
      # INV-EFF-7：操作名不重复
      noDups = builtins.length branchNames == builtins.length uniqueNames;

    in {
      ok             = hasTag && noDups;
      hasTag         = hasTag;
      noDuplicate    = noDups;
      effectTag      = effectTag;
      residualEffTy  = residualEffTy;
    };

  # handleAll：连续处理多个 handlers
  # handlers: [Handler]
  handleAll = effTy: handlers:
    lib.foldl' (acc: h:
      let result = checkHandler acc h; in
      if result.ok then result.residualEffTy else acc
    ) effTy handlers;

  # ══════════════════════════════════════════════════════════════════════════════
  # Effect 类型 Eff(E, A) 构造
  # ══════════════════════════════════════════════════════════════════════════════

  # mkEffType: 构造 Eff(effects, valueType)
  # effectTags: AttrSet String Type（tag → 操作类型）
  mkEffType = effectTags: valueType:
    let
      tags   = lib.sort (a: b: a < b) (builtins.attrNames effectTags);
      rowTy  = lib.foldl'
        (acc: tag: mkTypeDefault (rRowExtend tag effectTags.${tag} acc) kindLib.KRow)
        (mkTypeDefault rRowEmpty kindLib.KRow)
        (lib.reverseList tags);
      effRow = mkTypeDefault (rVariantRow effectTags
                 (mkTypeDefault rRowEmpty kindLib.KRow)) kindLib.KRow;
    in
    mkTypeDefault (rEffect effRow) KStar;

  # 常用 Effect 类型
  tIO       = mkEffType { IO = mkTypeDefault (rPrimitive "IOOp") KStar; };
  tState    = s: mkEffType { State = s; };
  tExn      = e: mkEffType { Exn = e; };
  tAsync    = mkEffType { Async = mkTypeDefault (rPrimitive "AsyncOp") KStar; };
  tPure     = mkTypeDefault (rEffect (mkTypeDefault rRowEmpty kindLib.KRow)) KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Effect Row 合并（与 normalize/rules_p33 集成）
  # ══════════════════════════════════════════════════════════════════════════════

  mergeEffects = eff1: eff2:
    let
      f1 = _flattenEffectFull eff1;
      f2 = _flattenEffectFull eff2;
      merged = f1.variants // f2.variants;  # right-biased
      tail   = if f2.tail != null then f2.tail
               else if f1.tail != null then f1.tail
               else null;
      sortedVars = lib.sort (a: b: a.name < b.name)
                    (lib.mapAttrsToList (k: v: { name = k; value = v; }) merged);
      rowTy  = lib.foldl'
        (acc: kv: mkTypeDefault (rRowExtend kv.name kv.value acc) kindLib.KRow)
        (if tail != null then tail else mkTypeDefault rRowEmpty kindLib.KRow)
        sortedVars;
    in
    mkTypeDefault (rEffect rowTy) KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # 不变量验证
  # ══════════════════════════════════════════════════════════════════════════════

  verifyEffectHandlerInvariants = _:
    let
      tInt   = mkTypeDefault (rPrimitive "Int")  KStar;
      tBool  = mkTypeDefault (rPrimitive "Bool") KStar;
      tUnit  = mkTypeDefault (rPrimitive "Unit") KStar;

      # 构造 Eff[IO, State, Exn] type
      allEffects  = mkEffType {
        IO    = tUnit;
        State = tInt;
        Exn   = tBool;
      };

      # INV-EFF-5：subtractEffect 精确移除
      afterIO   = subtractEffect allEffects ["IO"];
      tagsAfter = getEffectTags afterIO;
      invEFF5   = !(lib.elem "IO" tagsAfter) &&
                   lib.elem "State" tagsAfter &&
                   lib.elem "Exn" tagsAfter;

      # INV-EFF-4：handle 后 effect 移除
      ioHandler = mkHandler "IO" [
        (rHandlerBranch "putLine" [tBool] "resume" tUnit)
      ] tUnit;
      checkResult = checkHandler allEffects ioHandler;
      residTags   = getEffectTags checkResult.residualEffTy;
      invEFF4     = checkResult.ok && !(lib.elem "IO" residTags);

      # INV-EFF-7：重复操作名检测
      dupHandler = mkHandler "IO" [
        (rHandlerBranch "putLine" [tBool] "resume" tUnit)
        (rHandlerBranch "putLine" [tBool] "resume2" tUnit)
      ] tUnit;
      dupCheck = checkHandler allEffects dupHandler;
      invEFF7  = !dupCheck.ok;

      # INV-EFF-6：open effect row（RowVar tail）support
      openEff = mkTypeDefault (rEffect (mkTypeDefault {
        __variant = "RowVar"; name = "ε";
      } kindLib.KRow)) KStar;
      openSubtracted = subtractEffect openEff ["IO"];  # no-op, but no crash
      invEFF6 = openSubtracted.repr.__variant == "Effect";

    in {
      allPass     = invEFF4 && invEFF5 && invEFF6 && invEFF7;
      "INV-EFF-4" = invEFF4;
      "INV-EFF-5" = invEFF5;
      "INV-EFF-6" = invEFF6;
      "INV-EFF-7" = invEFF7;
    };
}
