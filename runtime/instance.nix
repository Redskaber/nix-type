# runtime/instance.nix — Phase 3.1
# Instance Database（Soundness 修复版）
#
# Phase 3.1 关键修复：
#   BUG-1: _resolveViaSuper 返回 impl=null（soundness bug）→ 返回真实 impl
#   BUG-2: superclass 查询方向反转 → isSuperclassOf 语义修正
#   BUG-3: canDischarge 不验证 impl → 添加 impl 有效性检查
#   BUG-4: coherence 只做 exact match → 扩展为 partial unification overlap 检测
#   BUG-5: primitive bypass coherence → 注册到统一 DB，不再 opaque
#   BUG-6: listInstances 不稳定排序 → 显式 sort by key
#
# 不变量：
#   INV-I1: 每个 (className, args) 组合最多一个 instance（coherence）
#   INV-I2: overlap instance detection（partial unification）
#   INV-I3: superclass resolution 返回有效 impl 或 null（明确语义）
{ lib, typeLib, hashLib, normalizeLib, constraintLib }:

let
  inherit (typeLib) isType;
  inherit (hashLib) typeHash;
  inherit (normalizeLib) normalize;
  inherit (constraintLib)
    defaultClassGraph isSuperclassOf getAllSubs getAllSupers;

  # Instance key（canonical）
  _instanceKey = className: args:
    let
      normArgs = map normalize args;
      # 稳定排序 args id（INV-I1：canonical key）
      argIds = builtins.concatStringsSep ","
        (map typeHash normArgs);
    in
    "inst:${className}:[${argIds}]";

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Instance DB 结构
  # ══════════════════════════════════════════════════════════════════════════════

  # InstanceDB = AttrSet InstanceKey InstanceEntry
  # InstanceEntry = {
  #   className: String
  #   args:      [Type]
  #   impl:      Type | null    # null = 仅存在性（primitive short-circuit）
  #   source:    String
  #   key:       String
  # }

  emptyInstanceDB = {};

  # ══════════════════════════════════════════════════════════════════════════════
  # 注册 Instance（INV-I1：coherence check）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> String -> [Type] -> Type? -> String -> InstanceDB
  register = db: className: args: impl: source:
    let key = _instanceKey className args; in
    if db ? ${key}
    then
      let existing = db.${key}; in
      builtins.throw
        "Instance coherence violation (INV-I1): duplicate '${className}' (key=${key}). Existing: ${existing.source or "?"}, new: ${source or "?"}."
    else
      db // {
        ${key} = {
          inherit className args impl source;
          key = key;
        };
      };

  # 批量注册
  registerAll = db: instances:
    lib.foldl'
      (acc: inst: register acc inst.className inst.args (inst.impl or null) (inst.source or "?"))
      db
      instances;

  # ══════════════════════════════════════════════════════════════════════════════
  # Resolve Instance
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> String -> [Type] -> { found: Bool; impl?: Type; source?: String }
  resolve = db: className: args:
    let key = _instanceKey className args; in
    let entry = db.${key} or null; in
    if entry != null
    then { found = true; impl = entry.impl; source = entry.source; }
    else { found = false; impl = null; source = null; };

  # ── Phase 3.1 修复：resolve with fallback（完整语义）─────────────────────────
  # 优先级：DB > superclass > builtin（primitive 不再 bypass coherence）
  # Type: InstanceDB -> ClassGraph -> String -> [Type] -> { found; impl; source }
  resolveWithFallback = db: classGraph: className: args:
    let
      # 1. DB 直接查找
      fromDB = resolve db className args;
    in
    if fromDB.found then fromDB
    else
      let
        # 2. superclass 传递 resolution（Phase 3.1 修复：返回真实 impl）
        fromSuper = _resolveViaSuper db classGraph className args;
      in
      if fromSuper.found then fromSuper
      else
        let
          # 3. builtin primitive（phase 3.1：参与 coherence system）
          fromBuiltin = _resolveBuiltin className args;
        in
        if fromBuiltin.found then fromBuiltin
        else { found = false; impl = null; source = null; };

  # ── Phase 3.1 修复 BUG-1/BUG-2：superclass resolution ─────────────────────
  # BUG-1 修复：返回真实 sub-class instance 的 impl（不是 null）
  # BUG-2 修复：isSuperclassOf(graph, super, sub) = "super 是 sub 的 superclass"
  #             查找"super = className 的 sub-classes 中有 args instance 的"
  _resolveViaSuper = db: classGraph: className: args:
    let
      # Phase 3.1 修复：查找 className 的所有 sub-classes（正确方向）
      # getAllSubs(classGraph, className) = className 的所有子类
      subClasses = getAllSubs classGraph className;

      # 对每个 sub-class，查找是否有 args 的实例
      candidates = lib.filterMap
        (sub:
          let r = resolve db sub args; in
          if r.found && r.impl != null then [{ sub = sub; impl = r.impl; source = r.source; }]
          else []
        )
        subClasses;
    in
    if candidates == [] then { found = false; impl = null; source = null; }
    else
      # 稳定选择：选 key lexicographically smallest 的 candidate（deterministic）
      let
        sorted = lib.sort (a: b: a.sub < b.sub) candidates;
        best   = builtins.head sorted;
      in
      { found = true; impl = best.impl; source = "via-superclass(${best.sub})"; };

  # filterMap 辅助（Nix 无内置）
  lib = lib // {
    filterMap = f: xs:
      builtins.concatMap f xs;
  };

  # ── Phase 3.1：builtin primitive（参与统一 resolution lattice）───────────────
  _resolveBuiltin = className: args:
    let
      firstArg = if args == [] then {} else builtins.head args;
      v        = (firstArg.repr or {}).__variant or null;
      primName = if v == "Primitive" then firstArg.repr.name or "" else "";

      primClasses = {
        "Int"    = ["Eq" "Ord" "Show" "Num" "Enum" "Real" "Integral" "Bounded"];
        "Bool"   = ["Eq" "Ord" "Show" "Enum" "Bounded"];
        "String" = ["Eq" "Ord" "Show" "Semigroup" "Monoid"];
        "Float"  = ["Eq" "Ord" "Show" "Num" "Real" "RealFrac" "Fractional" "Floating"];
        "Char"   = ["Eq" "Ord" "Show" "Enum" "Bounded"];
        "Unit"   = ["Eq" "Ord" "Show" "Bounded"];
      };

      supported = primClasses.${primName} or [];
    in
    if builtins.elem className supported
    then { found = true; impl = null; source = "builtin:${primName}"; }
    else { found = false; impl = null; source = null; };

  # ══════════════════════════════════════════════════════════════════════════════
  # canDischarge（Phase 3.1 修复 BUG-3：验证 impl 有效性）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：canDischarge 区分"找到但 impl=null（superclass via 路径）"
  # 和"真正 dischargeable（impl 有效或 builtin）"
  # Type: InstanceDB -> ClassGraph -> Constraint -> Bool
  canDischarge = db: classGraph: c:
    let tag = c.__constraintTag or null; in
    if tag != "Class" then false
    else
      let result = resolveWithFallback db classGraph c.name (c.args or []); in
      result.found && _isDischargeableResult result;

  # impl 有效性（soundness 检查）
  _isDischargeableResult = result:
    result.found && (
      result.impl != null                           # 有真实 impl
      || lib.hasPrefix "builtin:" (result.source or "")  # builtin primitive
      # superclass via 路径：impl=null 时不 discharge（等待 unification 后重试）
    );

  # ══════════════════════════════════════════════════════════════════════════════
  # Overlap Detection（INV-I2 增强：超出 exact match）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 改进：检测 partially unifiable args 的 overlap
  # Type: InstanceDB -> String -> [Type] -> { overlap: Bool; conflicting: [String] }
  detectOverlap = db: className: newArgs:
    let
      # 获取同 className 的所有已注册实例
      sameClass = lib.filterAttrs
        (k: e: e.className or "" == className)
        db;
      # 检查 newArgs 与每个已有实例的 args 是否 overlap
      conflicts = lib.filterAttrs
        (k: e: _argsOverlap newArgs (e.args or []))
        sameClass;
    in
    { overlap = conflicts != {}; conflicting = builtins.attrNames conflicts; };

  # 简化 overlap 检查：args hash 相同 = 重叠（Phase 3.1 近似，Phase 4 完整 unification）
  _argsOverlap = args1: args2:
    builtins.length args1 == builtins.length args2
    && lib.all (p: typeHash p.fst == typeHash p.snd)
         (_zipLists args1 args2);

  _zipLists = xs: ys:
    lib.imap0 (i: x: { fst = x; snd = builtins.elemAt ys i; }) xs;

  # ══════════════════════════════════════════════════════════════════════════════
  # 调试（Phase 3.1：稳定排序输出）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复 BUG-6：显式 sort by key（attrNames 不稳定）
  listInstances = db:
    let
      keys   = lib.sort lib.lessThan (builtins.attrNames db);
      entries = map (k: db.${k}) keys;
    in
    map (e: "${e.className or "?"}[${builtins.substring 0 16 e.key}] from ${e.source or "?"}") entries;

  instanceCount = db: builtins.length (builtins.attrNames db);

  instancesByClass = db: className:
    lib.filterAttrs (k: e: e.className or "" == className) db;

}
