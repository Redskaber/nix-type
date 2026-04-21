# runtime/instance.nix — Phase 3
# Instance Database（Phase 3：Coherence 强化 + 超类传递）
#
# Phase 3 新增：
#   coherence check：重叠 instance 检测（INV-I2）
#   superclass 传递 discharge（Class graph 集成）
#   resolve with fallback（内置 + DB + superclass）
#   withBuiltinInstances：常用原始类型实例
{ lib, typeLib, hashLib, normalizeLib, constraintLib }:

let
  inherit (typeLib) isType;
  inherit (hashLib) typeHash;
  inherit (normalizeLib) normalize;
  inherit (constraintLib)
    mkClass defaultClassGraph isSuperclassOf;

  # Instance key：className + normalized arg ids
  _instanceKey = className: args:
    let
      normArgs = map normalize args;
      argIds   = builtins.concatStringsSep ","
        (map typeHash normArgs);
    in
    "inst:${className}:[${argIds}]";

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Instance DB 结构
  # ══════════════════════════════════════════════════════════════════════════════

  # InstanceDB = AttrSet InstanceKey InstanceEntry
  # InstanceEntry = { className: String; args: [Type]; impl: Type; source: String }

  emptyInstanceDB = {};

  # ══════════════════════════════════════════════════════════════════════════════
  # 注册 Instance（INV-I2：coherence check）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> String -> [Type] -> Type -> String -> InstanceDB
  register = db: className: args: impl: source:
    let key = _instanceKey className args; in
    if db ? ${key}
    then
      # Coherence violation：重叠 instance
      let existing = db.${key}; in
      builtins.throw
        "Instance coherence violation: duplicate instance for ${className} (key=${key}). Existing from ${existing.source or "?"}, new from ${source or "?"}."
    else
      db // {
        ${key} = {
          inherit className args impl source;
          key = key;
        };
      };

  # 批量注册（用于模块初始化）
  registerAll = db: instances:
    lib.foldl'
      (acc: inst: register acc inst.className inst.args inst.impl (inst.source or "?"))
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
    else { found = false; };

  # ── resolve with fallback chain ──────────────────────────────────────────
  # 1. 内置原始类型实例
  # 2. DB 查找
  # 3. 超类传递
  resolveWithFallback = db: classGraph: className: args:
    let
      # 1. primitive
      prim = _resolvePrimitive className args;
      # 2. DB
      fromDB = resolve db className args;
      # 3. 超类（via subclass instance）
      fromSuper = _resolveViaSuper db classGraph className args;
    in
    if prim.found    then prim
    else if fromDB.found  then fromDB
    else if fromSuper.found then fromSuper
    else { found = false; };

  # ── 超类传递 resolve ─────────────────────────────────────────────────────
  _resolveViaSuper = db: classGraph: className: args:
    let
      # 查找 className 的所有子类
      subClasses = builtins.filter
        (sub: isSuperclassOf classGraph className sub)
        (builtins.attrNames classGraph);
      # 检查是否有 args 的子类实例
      found = lib.any
        (sub: (resolve db sub args).found)
        subClasses;
    in
    if found
    then { found = true; impl = null; source = "via-superclass"; }
    else { found = false; };

  # ── 原始类型内置实例 ──────────────────────────────────────────────────────
  _resolvePrimitive = className: args:
    let
      firstArg = builtins.head (args ++ [{}]);
      v        = (firstArg.repr or {}).__variant or null;
      primName = if v == "Primitive" then firstArg.repr.name or "" else "";

      classes = {
        "Int"    = ["Eq" "Ord" "Show" "Num" "Enum" "Real" "Integral" "Bounded"];
        "Bool"   = ["Eq" "Ord" "Show" "Enum" "Bounded"];
        "String" = ["Eq" "Ord" "Show" "Semigroup" "Monoid"];
        "Float"  = ["Eq" "Ord" "Show" "Num" "Real" "RealFrac" "Fractional" "Floating"];
        "Char"   = ["Eq" "Ord" "Show" "Enum" "Bounded"];
        "Unit"   = ["Eq" "Ord" "Show" "Bounded"];
      };

      supported = classes.${primName} or [];
    in
    if builtins.elem className supported
    then { found = true; impl = null; source = "builtin:${primName}"; }
    else { found = false; };

  # ══════════════════════════════════════════════════════════════════════════════
  # 内置 Instances（常用泛型 instances）
  # ══════════════════════════════════════════════════════════════════════════════

  withBuiltinInstances = db: db;
  # 原始类型通过 _resolvePrimitive 处理，无需注册到 DB

  # ══════════════════════════════════════════════════════════════════════════════
  # Discharge（constraint solver 用）
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: InstanceDB -> ClassGraph -> Constraint -> Bool
  canDischarge = db: classGraph: c:
    let tag = c.__constraintTag or null; in
    if tag != "Class" then false
    else (resolveWithFallback db classGraph c.name (c.args or [])).found;

  # ══════════════════════════════════════════════════════════════════════════════
  # 调试 / 列举
  # ══════════════════════════════════════════════════════════════════════════════

  listInstances = db:
    map (key:
      let e = db.${key}; in
      "${e.className or "?"}[${key}] from ${e.source or "?"}") (builtins.attrNames db);

  instanceCount = db: builtins.length (builtins.attrNames db);

}
