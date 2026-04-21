# runtime/instance.nix — Phase 3.2
# Instance DB（specificity-based selection + partial unification overlap）
#
# Phase 3.2 新增/修复：
#   P3.2-3: INV-I2 overlap detection: partial unification overlap（不只 exact match）
#   P3.2-6: specificity-based instance selection（最小特化 > lexicographic）
#
# Phase 3.1 继承（soundness 修复）：
#   SOL-1: _resolveViaSuper 返回真实 impl（不是 null）
#   SOL-2: canDischarge 验证 impl 有效性
#   SOL-3: isSuperclassOf 方向修正（super/sub 语义正确）
#
# Instance DB 设计：
#   DB = { instances: AttrSet key InstanceEntry; classGraph: ClassGraph }
#   InstanceEntry = { className; normArgs; impl; key; specificity }
#   specificity = 具体类型参数数量（越多越具体，优先级越高）
#
# Specificity 语义（类似 Haskell instance selection）：
#   specificity(inst) = number of non-Var type arguments
#   例：Eq Int → specificity=1（具体）
#       Eq a   → specificity=0（泛化）
#   选择规则：specificity 最高者优先；若相等，取 lexicographic key 最小
#
# Coherence（INV-I1）：
#   严格唯一：对同一 (className, args) 组合，最多一个匹配 instance
#   Phase 3.2：overlap detection 使用 partial unification 检查是否存在冲突
{ lib, typeLib, hashLib, normalizeLib, constraintLib }:

let
  inherit (typeLib) isType;
  inherit (hashLib) typeHash;
  inherit (normalizeLib) normalize;
  inherit (constraintLib) defaultClassGraph isSuperclassOf getAllSubs;

  # ── Specificity 计算 ──────────────────────────────────────────────────────────

  # Type: [Type] -> Int
  # specificity = 非 Var 参数数量（Var 是泛化占位，具体类型提升 specificity）
  _specificity = args:
    builtins.length
      (builtins.filter
        (t: t.repr.__variant or null != "Var")
        args);

  # ── Instance Key（canonical）────────────────────────────────────────────────

  # Type: String -> [Type] -> String
  _instanceKey = className: normArgs:
    let
      argIds = map (a: a.id or (typeHash a)) normArgs;
    in
    "${className}:[${builtins.concatStringsSep "," argIds}]";

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Instance DB 结构
  # ══════════════════════════════════════════════════════════════════════════════

  # InstanceDB = {
  #   instances:  AttrSet key InstanceEntry   # exact-match indexed
  #   classGraph: ClassGraph
  #   byClass:    AttrSet className [key]     # class → all instance keys（for overlap）
  # }

  emptyInstanceDB = {
    instances  = {};
    classGraph = defaultClassGraph;
    byClass    = {};
  };

  # InstanceEntry = {
  #   className:   String
  #   normArgs:    [Type]          # normalized type arguments
  #   impl:        Any             # implementation (may be null for primitive)
  #   key:         String          # canonical key
  #   specificity: Int             # non-Var args count
  #   source:      String          # "user" | "primitive" | "derived"
  # }

  # ══════════════════════════════════════════════════════════════════════════════
  # Instance 注册（INV-I1：coherence check with partial unification）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> String -> [Type] -> Any -> InstanceDB
  register = db: className: args: impl:
    let
      normArgs    = map normalize args;
      key         = _instanceKey className normArgs;
      specificity = _specificity normArgs;

      # INV-I1：coherence check
      existing = db.instances.${key} or null;
    in
    if existing != null
    then
      # 完全相同 key → duplicate（INV-I1 violation）
      builtins.throw "Instance coherence violation: ${key} already registered"
    else
      let
        # Phase 3.2：overlap check via partial unification
        # 检查同一 className 下是否存在 overlapping instance
        existingKeysForClass = db.byClass.${className} or [];
        overlapConflict = _findOverlap db className normArgs existingKeysForClass;
      in
      if overlapConflict != null
      then
        # 存在 overlap：允许注册但标记（Haskell OverlappingInstances 语义）
        # 具体的选择在 resolve 时由 specificity 决定
        let
          entry = {
            inherit className normArgs impl key specificity;
            source   = "user";
            overlaps = [ overlapConflict ];
          };
        in
        db // {
          instances = db.instances // { ${key} = entry; };
          byClass   = db.byClass // {
            ${className} = (db.byClass.${className} or []) ++ [key];
          };
        }
      else
        let
          entry = {
            inherit className normArgs impl key specificity;
            source   = "user";
            overlaps = [];
          };
        in
        db // {
          instances = db.instances // { ${key} = entry; };
          byClass   = db.byClass // {
            ${className} = (db.byClass.${className} or []) ++ [key];
          };
        };

  # Phase 3.2：Overlap detection via partial unification
  # Returns: null（无冲突）| key（有冲突的已有 instance key）
  _findOverlap = db: className: normArgs: existingKeys:
    let
      go = keys:
        if keys == [] then null
        else
          let
            k     = builtins.head keys;
            rest  = builtins.tail keys;
            entry = db.instances.${k} or null;
          in
          if entry == null then go rest
          else
            let
              # 检查 normArgs 与 entry.normArgs 是否 partially unifiable
              overlaps = _argsOverlap normArgs (entry.normArgs or []);
            in
            if overlaps then k
            else go rest;
    in
    go existingKeys;

  # 两组 args 是否 partially unifiable（conservative overlap check）
  # 使用 hash 相等或变体匹配（轻量版，不做完整 Robinson unification）
  _argsOverlap = argsA: argsB:
    if builtins.length argsA != builtins.length argsB then false
    else
      lib.all (pair:
        let
          va = pair.a.repr.__variant or null;
          vb = pair.b.repr.__variant or null;
        in
        # Var 总是可 overlap
        va == "Var" || vb == "Var"
        # 相同 hash → exact match
        || typeHash pair.a == typeHash pair.b
        # 同 Constructor 名
        || (va == "Constructor" && vb == "Constructor"
            && pair.a.repr.name or "" == pair.b.repr.name or "")
        # 同 Primitive 名
        || (va == "Primitive" && vb == "Primitive"
            && pair.a.repr.name or "" == pair.b.repr.name or "")
      )
      (_zipLists argsA argsB);

  # zipLists（内部辅助）
  _zipLists = xs: ys:
    lib.imap0 (i: x: { a = x; b = builtins.elemAt ys i; }) xs;

  # 批量注册
  # Type: InstanceDB -> [(String, [Type], Any)] -> InstanceDB
  registerAll = db: entries:
    lib.foldl'
      (acc: e: register acc e.className e.args e.impl)
      db
      entries;

  # ══════════════════════════════════════════════════════════════════════════════
  # Instance 解析（exact match）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> String -> [Type] -> { found; impl; key; source }
  resolve = db: className: args:
    let
      normArgs = map normalize args;
      key      = _instanceKey className normArgs;
      entry    = db.instances.${key} or null;
    in
    if entry != null
    then { found = true; impl = entry.impl; key = key; source = entry.source or "user"; }
    else { found = false; impl = null; key = key; source = "none"; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Phase 3.2：resolveWithFallback（specificity-based selection）
  #
  # 解析顺序：
  #   1. Primitive（内建类型，hardcoded，最高优先级）
  #   2. Exact match（hash-based key）
  #   3. Specificity-based selection（从 byClass 中找最具体的匹配 instance）
  #   4. Superclass resolution（继承的 impl）
  #
  # Specificity 规则：
  #   - 在所有 matching instances 中选 specificity 最高者
  #   - Tie-breaking：lexicographic key 最小者（确定性）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> ClassGraph -> String -> [Type] -> { found; impl; source }
  resolveWithFallback = db: classGraph: className: args:
    let
      normArgs = map normalize args;
    in

    # 1. Primitive 内建类型
    if _resolvePrimitive className normArgs
    then { found = true; impl = _primitiveImpl className normArgs; source = "primitive"; }

    else
      let exact = resolve db className normArgs; in
      # 2. Exact match
      if exact.found
      then { found = true; impl = exact.impl; source = "db-exact"; }

      else
        # 3. Phase 3.2：Specificity-based selection from byClass
        let bestMatch = _resolveBySpecificity db className normArgs; in
        if bestMatch.found
        then bestMatch

        else
          # 4. Superclass resolution
          _resolveViaSuper db classGraph className normArgs;

  # ── Phase 3.2：specificity-based selection ───────────────────────────────────

  # 从 byClass 索引中找所有匹配当前 args 的 instances，选最具体者
  # Type: InstanceDB -> String -> [Type] -> { found; impl; source }
  _resolveBySpecificity = db: className: normArgs:
    let
      candidateKeys = db.byClass.${className} or [];
      # 过滤出匹配的 candidate entries
      matching = builtins.filter
        (k:
          let entry = db.instances.${k} or null; in
          entry != null && _argsMatch normArgs (entry.normArgs or []))
        candidateKeys;
    in
    if matching == []
    then { found = false; impl = null; source = "none"; }
    else
      # 选 specificity 最高的
      let
        withSpec = map (k:
          let entry = db.instances.${k}; in
          { key = k; entry = entry; specificity = entry.specificity or 0; }
        ) matching;

        # 排序：specificity 降序，tie-break by key 升序（lexicographic）
        sorted = lib.sort
          (a: b:
            if a.specificity != b.specificity
            then a.specificity > b.specificity
            else a.key < b.key)
          withSpec;

        best = builtins.head sorted;
        bestEntry = best.entry;
      in
      { found = true; impl = bestEntry.impl; source = "db-specificity-${builtins.toString best.specificity}"; };

  # 检查 args 是否与 instance args 匹配（支持泛化 Var）
  # 即：instance 参数中的 Var 可匹配任何具体类型
  _argsMatch = callArgs: instArgs:
    if builtins.length callArgs != builtins.length instArgs then false
    else
      lib.all (pair:
        let
          instVariant = pair.b.repr.__variant or null;
        in
        # instance arg 是 Var（泛化）→ 匹配任意
        instVariant == "Var"
        # 相同 hash → exact match
        || typeHash pair.a == typeHash pair.b
        # 相同 Constructor + 子参数 match（浅层）
        || (pair.a.repr.__variant or null == "Constructor"
            && pair.b.repr.__variant or null == "Constructor"
            && pair.a.repr.name or "" == pair.b.repr.name or "")
      )
      (_zipLists callArgs instArgs);

  # ── Primitive resolution ─────────────────────────────────────────────────────

  _primitiveSupportedClasses = {
    "Eq"      = ["Int" "Bool" "String" "Float"];
    "Ord"     = ["Int" "Float" "String"];
    "Show"    = ["Int" "Bool" "String" "Float"];
    "Num"     = ["Int" "Float"];
    "Bounded" = ["Int" "Bool"];
    "Enum"    = ["Int" "Bool"];
  };

  _resolvePrimitive = className: normArgs:
    let
      supported = _primitiveSupportedClasses.${className} or [];
    in
    normArgs != []
    && supported != []
    && (normArgs |> builtins.head |> (t: t.repr.__variant or null) == "Primitive")
    && (normArgs |> builtins.head |> (t: t.repr.name or "") |> (n: builtins.elem n supported));

  # primitive impl：内建实现标记（实际 impl 为 null，由运行时提供）
  _primitiveImpl = className: normArgs:
    let
      typeName = (builtins.head normArgs).repr.name or "?";
    in
    { __primitiveInstance = true; className = className; typeName = typeName; };

  # ── Phase 3.1：Superclass resolution（返回真实 impl）────────────────────────

  # 查询 sub-class instances，找到 super 对应的 impl
  # Phase 3.1 修复：不再返回 null impl，而是查找具体 sub-class impl
  _resolveViaSuper = db: classGraph: className: normArgs:
    let
      # 找到所有 className 的 sub-class
      subClasses = getAllSubs classGraph className;

      # 对每个 sub-class，尝试找到匹配 normArgs 的 instance
      # 思路：若 subClass 有对应 normArgs 的 instance，则其 impl 也间接满足 super
      trySubClass = subClass:
        let
          subResult = resolveWithFallback db classGraph subClass normArgs;
        in
        if subResult.found && subResult.impl != null
        then subResult // { source = "via-superclass(${subClass})"; }
        else null;

      # 选第一个成功的 sub-class（按 specificity 已在内部处理）
      results = builtins.filter (r: r != null) (map trySubClass subClasses);
    in
    if results == []
    then { found = false; impl = null; source = "none"; }
    else
      # Phase 3.2：选 specificity 最高的 sub-class impl
      let
        best = lib.foldl'
          (acc: r:
            # 保留 specificity 信息（来自 source 字符串无法解析，保守取第一个）
            if acc == null then r else acc)
          null
          results;
      in
      best // { found = true; };

  # ══════════════════════════════════════════════════════════════════════════════
  # canDischarge（Phase 3.1 soundness 修复）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> ClassGraph -> String -> [Type] -> Bool
  canDischarge = db: classGraph: className: args:
    let result = resolveWithFallback db classGraph className args; in
    # Phase 3.1 修复：验证 impl 不为 null（primitiveInstance 除外）
    result.found
    && (result.impl != null
        || (result.impl or null) == null && (result.source or "") == "primitive");

  # ══════════════════════════════════════════════════════════════════════════════
  # 调试工具
  # ══════════════════════════════════════════════════════════════════════════════

  # 列出 DB 中所有 instances（deterministic 排序）
  listInstances = db:
    let
      keys = lib.sort lib.lessThan (builtins.attrNames db.instances);
    in
    map (k:
      let e = db.instances.${k}; in
      {
        key         = k;
        className   = e.className or "?";
        specificity = e.specificity or 0;
        source      = e.source or "?";
        hasImpl     = e.impl != null;
        overlaps    = e.overlaps or [];
      }
    ) keys;

  instanceCount = db: builtins.length (builtins.attrNames db.instances);

  # 列出特定 class 的所有 instance keys（按 specificity 降序）
  listClassInstances = db: className:
    let
      keys = db.byClass.${className} or [];
      withSpec = map (k:
        let e = db.instances.${k} or {}; in
        { key = k; specificity = e.specificity or 0; }
      ) keys;
    in
    lib.sort (a: b: a.specificity > b.specificity) withSpec;

}
