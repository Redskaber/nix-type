# runtime/instance.nix — Phase 4.1
# Instance DB：typeclass 实例系统
# 修复 Phase 3.x 关键 bugs：
#   - RISK-A: canDischarge 现在验证 impl != null（soundness）
#   - RISK-B: instanceKey 使用 NF-hash（INV-4 coherence）
#   - superclass resolution 返回真实 impl（不再是 null）
#   - coherence 覆盖 exact match（INV-I2）
{ lib, typeLib, reprLib, kindLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType;
  inherit (hashLib) typeHash instanceKey;
  inherit (normalizeLib) normalize';

in rec {
  # ── Instance DB 结构 ──────────────────────────────────────────────────────
  # DB = {
  #   instances : AttrSet(key -> InstanceEntry)
  #   byClass   : AttrSet(className -> [key])
  # }
  # InstanceEntry = {
  #   className   : String
  #   args        : [Type]         -- 规范化后
  #   impl        : Any | null     -- null 仅对 primitive builtins
  #   specificity : Int            -- 越高越优先（overlapping 时）
  #   source      : String         -- "user" | "primitive" | "derived"
  #   overlaps    : [String]       -- 已知 overlap instance keys
  # }

  emptyDB = { instances = {}; byClass = {}; };

  # ── 内部 key 生成（INV-4: NF-hash based，修复 RISK-B）────────────────────
  # Type: String -> [Type] -> String
  _instanceKey = className: args:
    let
      normArgs = map normalize' args;
      argHashes = map (a: typeHash a) normArgs;
    in
    # sha256 of (className, sorted argHashes) — canonical
    builtins.hashString "sha256"
      (builtins.toJSON { c = className; a = argHashes; });

  # ── Instance 注册 ─────────────────────────────────────────────────────────
  # Type: DB -> String -> [Type] -> Any -> AttrSet -> DB
  registerInstance = db: className: args: impl: opts:
    let
      key         = _instanceKey className args;
      specificity = opts.specificity or 0;
      source      = opts.source or "user";
      overlaps    = opts.overlaps or [];
      normArgs    = map normalize' args;
      entry = {
        inherit className specificity source overlaps;
        args   = normArgs;
        impl   = impl;
        key    = key;
      };
      # INV-I1: 禁止完全相同 key 的重复注册（exact coherence）
      existing = db.instances.${key} or null;
      # INV-I2: 检测 overlap（简化：仅 exact key 检测；Phase 4.2 扩展部分合一）
      conflict = existing != null && existing.source != "primitive";
    in
    if conflict then
      builtins.throw "Instance coherence violation: duplicate instance for ${className}[${key}]"
    else
      let
        newInstances = db.instances // { ${key} = entry; };
        oldByClass   = db.byClass.${className} or [];
        newByClass   = db.byClass // { ${className} = oldByClass ++ [ key ]; };
      in
      { instances = newInstances; byClass = newByClass; };

  # ── Primitive 内建 instances（不参与 coherence check，不可覆盖）──────────
  _primitiveClasses = [ "Eq" "Ord" "Show" "Num" "Bool" "Hashable" ];

  _resolvePrimitive = className: args:
    let
      supported = _primitiveClasses;
      isSup = builtins.elem className supported;
    in
    if !isSup then { found = false; impl = null; source = "none"; }
    else
      let
        firstArg = if args == [] then null else builtins.head args;
        primName = if firstArg == null then null
                   else firstArg.repr.name or null;
        isBuiltinPrim = primName != null &&
          builtins.elem primName [ "Int" "Bool" "String" "Float" "Null" ];
      in
      if isBuiltinPrim
      then
        { found       = true;
          # primitive impl 是标记（非 null），表示"内建实现"
          impl        = { __primImpl = true; className = className; typeName = primName; };
          source      = "primitive";
          specificity = 100; }  # primitive 优先级最高
      else { found = false; impl = null; source = "none"; };

  # ── DB 查询（exact match）───────────────────────────────────────────────
  _resolveExact = db: className: args:
    let key = _instanceKey className args; in
    if db.instances ? ${key}
    then
      let e = db.instances.${key}; in
      { found       = true;
        impl        = e.impl;
        source      = e.source;
        specificity = e.specificity; }
    else { found = false; impl = null; source = "none"; specificity = 0; };

  # ── Superclass resolution（修复 RISK-A：返回真实 impl）────────────────────
  # Type: AttrSet(classGraph) -> DB -> String -> [Type] -> ResolveResult
  # classGraph: AttrSet(className -> [superclassName])
  _resolveViaSuperclass = classGraph: db: className: args:
    let
      # 找到 className 的所有直接子类（sub <: className）
      # 注意：classGraph[A] = [B, C] 表示 A 是 B 和 C 的超类
      # 我们需要找：谁的 superclasses 包含 className？
      allClasses = builtins.attrNames classGraph;
      subClasses = lib.filter (sub:
        builtins.elem className (classGraph.${sub} or [])
      ) allClasses;
      # 对每个 subclass，尝试查找 instance
      subResults = map (sub:
        let r = _resolveExact db sub args; in
        r // { subClass = sub; }
      ) subClasses;
      # 找到第一个有 impl != null 的
      validResults = lib.filter (r: r.found && r.impl != null) subResults;
    in
    if validResults == []
    then { found = false; impl = null; source = "none"; specificity = 0; }
    else
      # 选 specificity 最高的（deterministic selection）
      let best = lib.foldl'
        (acc: r: if r.specificity > acc.specificity then r else acc)
        (builtins.head validResults)
        (builtins.tail validResults);
      in
      { found       = best.found;
        impl        = best.impl;  # ← 修复 RISK-A：返回真实 impl
        source      = "via-superclass:${best.subClass}";
        specificity = best.specificity - 1; };  # 降低一档优先级

  # ── 主 resolution pipeline（primitive → exact → superclass）─────────────
  # Type: AttrSet(classGraph) -> DB -> String -> [Type] -> ResolveResult
  resolveWithFallback = classGraph: db: className: args:
    let
      # 阶段 1: primitive
      prim = _resolvePrimitive className args;
    in
    if prim.found then prim
    else
      let
        # 阶段 2: exact DB match
        exact = _resolveExact db className args;
      in
      if exact.found then exact
      else
        # 阶段 3: superclass resolution（修复 RISK-A）
        _resolveViaSuperclass classGraph db className args;

  # ── canDischarge（修复 RISK-A: 必须验证 impl != null）────────────────────
  # Type: AttrSet(classGraph) -> DB -> Constraint -> Bool
  canDischarge = classGraph: db: constraint:
    let tag = constraint.__constraintTag or null; in
    if tag == "Class" then
      let r = resolveWithFallback classGraph db constraint.className (constraint.args or []); in
      # 修复：found AND impl != null（soundness 保证）
      r.found && r.impl != null
    else false;

  # ── Instance listing（调试/反射用，stable 顺序）──────────────────────────
  listInstances = db:
    let keys = lib.sort (a: b: a < b) (builtins.attrNames db.instances); in
    map (key:
      let e = db.instances.${key}; in
      { inherit key;
        className   = e.className;
        specificity = e.specificity;
        source      = e.source;
        hasImpl     = e.impl != null;
        overlaps    = e.overlaps or []; }
    ) keys;

  listClassInstances = db: className:
    let
      keys = db.byClass.${className} or [];
      withSpec = map (k:
        let e = db.instances.${k} or {}; in
        { key = k; specificity = e.specificity or 0; }
      ) keys;
    in lib.sort (a: b: a.specificity > b.specificity) withSpec;

  instanceCount = db: builtins.length (builtins.attrNames db.instances);
}
