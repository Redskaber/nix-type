# constraint/ir.nix — Phase 3
# Constraint IR（结构化，INV-6）
#
# Phase 3 核心修复（来自 nix-todo/constraint/ir.md）：
#   1. _serType 替换为 deterministic canonical（消除 toJSON 顺序依赖）
#   2. applySubst 递归完整（委托给 substLib）
#   3. constraintsHash 去重（集合语义，不是 multiset）
#   4. normalizeConstraint 实现（统一入口，可组合）
#   5. Implies 规范化（premises 排序）
#   6. deduplicateConstraints O(n)（listToAttrs 优化）
#
# 不变量：
#   INV-6: Constraint ∈ TypeRepr（不是函数，不是 runtime）
#   INV-C1: constraintKey 是 deterministic（canonical）
#   INV-C2: constraintsHash 是集合语义（去重后 sorted hash）
#   INV-C3: applySubst 完整递归（所有 Type arg 都替换）
#   INV-C4: normalizeConstraint 是 idempotent
{ lib }:

rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraint 构造器
  # ══════════════════════════════════════════════════════════════════════════════

  _mkC = tag: fields: { __constraintTag = tag; } // fields;

  # Class 约束：类型类实现（e.g., Eq a, Show a）
  # Type: String -> [Type] -> Constraint
  mkClass = name: args:
    _mkC "Class" { inherit name args; };

  # Equality 约束：两个类型必须统一（e.g., a ~ Int）
  # Type: Type -> Type -> Constraint
  mkEquality = a: b:
    # 规范化：lexicographic 排序保证 Eq(a,b) == Eq(b,a)
    let
      idA = a.id or (builtins.hashString "md5" (builtins.toJSON a));
      idB = b.id or (builtins.hashString "md5" (builtins.toJSON b));
      ordered = if idA <= idB then { a = a; b = b; } else { a = b; b = a; };
    in
    _mkC "Equality" { inherit (ordered) a b; };

  # Predicate 约束：谓词约束（Liquid Types 准备）
  # fn: String（谓词标识符，不是 Nix 函数！INV-6）
  # Type: String -> Type -> Constraint
  mkPredicate = fn: arg:
    _mkC "Predicate" { inherit fn arg; };

  # Implies 约束：蕴含（premises → conclusion）
  # Type: [Constraint] -> Constraint -> Constraint
  mkImplies = premises: conclusion:
    let sorted = _sortConstraints premises; in
    _mkC "Implies" { premises = sorted; inherit conclusion; };

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraint 判断
  # ══════════════════════════════════════════════════════════════════════════════

  isConstraint = c: builtins.isAttrs c && c ? __constraintTag;
  isClass      = c: isConstraint c && c.__constraintTag == "Class";
  isEquality   = c: isConstraint c && c.__constraintTag == "Equality";
  isPredicate  = c: isConstraint c && c.__constraintTag == "Predicate";
  isImplies    = c: isConstraint c && c.__constraintTag == "Implies";

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraint Key（INV-C1：deterministic canonical）
  # Phase 3 修复：不用 toJSON（顺序依赖），改用 canonical serializer
  # ══════════════════════════════════════════════════════════════════════════════

  # Type: Constraint -> String
  constraintKey = c:
    let tag = c.__constraintTag or null; in
    if tag == "Class" then
      # canonical：sorted args by id
      let argIds = builtins.concatStringsSep ","
            (builtins.sort (a: b: a < b) (map (a: a.id or "?") (c.args or []))); in
      "Cls:${c.name}:[${argIds}]"
    else if tag == "Equality" then
      # mkEquality 已保证 canonical 顺序（idA <= idB）
      "Eq:${(c.a or {}).id or "?"}:${(c.b or {}).id or "?"}"
    else if tag == "Predicate" then
      "Pred:${c.fn or "?"}:${(c.arg or {}).id or "?"}"
    else if tag == "Implies" then
      let
        premKeys = builtins.sort (a: b: a < b) (map constraintKey (c.premises or []));
        conclKey = constraintKey (c.conclusion or {});
      in
      "Imp:[${builtins.concatStringsSep ";""  premKeys}]→${conclKey}"
    else "?c:${builtins.hashString "md5" (builtins.toJSON c)}";

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraint 集合操作
  # ══════════════════════════════════════════════════════════════════════════════

  # 去重（INV-C2：集合语义）O(n)
  # Type: [Constraint] -> [Constraint]
  deduplicateConstraints = cs:
    let
      table = builtins.listToAttrs
        (map (c: { name = constraintKey c; value = c; }) cs);
    in
    builtins.attrValues table;

  # 合并两个 constraint 集合
  # Type: [Constraint] -> [Constraint] -> [Constraint]
  mergeConstraints = cs1: cs2:
    deduplicateConstraints (cs1 ++ cs2);

  # Constraints Hash（INV-C2：去重 + sorted = canonical）
  # Type: [Constraint] -> String
  constraintsHash = cs:
    let
      dedup  = deduplicateConstraints cs;
      keys   = builtins.sort (a: b: a < b) (map constraintKey dedup);
    in
    builtins.hashString "sha256"
      (builtins.concatStringsSep ";" keys);

  # ── 内部：排序 constraints（canonical order）──────────────────────────────
  _sortConstraints = cs:
    builtins.sort (a: b: constraintKey a < constraintKey b) cs;

  # ══════════════════════════════════════════════════════════════════════════════
  # normalizeConstraint（Phase 3 新增：统一规范化入口，INV-C4）
  # ══════════════════════════════════════════════════════════════════════════════

  # 规范化 Constraint（幂等）
  # Type: Constraint -> Constraint
  normalizeConstraint = c:
    let tag = c.__constraintTag or null; in

    if tag == "Class" then
      # args 按 type id 排序（canonical）
      mkClass c.name (builtins.sort (a: b: (a.id or "") < (b.id or "")) (c.args or []))

    else if tag == "Equality" then
      # mkEquality 已规范化
      mkEquality c.a c.b

    else if tag == "Predicate" then c

    else if tag == "Implies" then
      # premises 规范化 + 排序，conclusion 规范化
      let
        normPremises  = map normalizeConstraint (c.premises or []);
        normConclusion = normalizeConstraint (c.conclusion or c);
        deduped = deduplicateConstraints normPremises;
      in
      mkImplies deduped normConclusion

    else c;

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraint Substitution（INV-C3：完整递归）
  # Phase 3 修复：不在 IR 中实现，委托给 substLib（避免循环依赖）
  # 但需要提供接口（substLib 会回调）
  # ══════════════════════════════════════════════════════════════════════════════

  # applySubstToConstraint 的轻量版本（不依赖 substLib）
  # Type: (Type -> Type) -> Constraint -> Constraint
  mapTypesInConstraint = f: c:
    let tag = c.__constraintTag or null; in

    if tag == "Class" then
      mkClass c.name (map f (c.args or []))

    else if tag == "Equality" then
      mkEquality (f c.a) (f c.b)

    else if tag == "Predicate" then
      _mkC "Predicate" { fn = c.fn; arg = f c.arg; }

    else if tag == "Implies" then
      mkImplies
        (map (mapTypesInConstraint f) (c.premises or []))
        (mapTypesInConstraint f (c.conclusion or c))

    else c;

  # ══════════════════════════════════════════════════════════════════════════════
  # Class 图（typeclass 层级关系）
  # ══════════════════════════════════════════════════════════════════════════════

  # superclasses: ClassName -> [ClassName]
  defaultClassGraph = {
    "Eq"         = [];
    "Ord"        = ["Eq"];
    "Show"       = [];
    "Num"        = ["Eq"];
    "Real"       = ["Num" "Ord"];
    "Integral"   = ["Real" "Enum"];
    "Fractional" = ["Num"];
    "Floating"   = ["Fractional"];
    "RealFrac"   = ["Real" "Fractional"];
    "Enum"       = [];
    "Bounded"    = [];
    "Functor"    = [];
    "Foldable"   = [];
    "Traversable" = ["Functor" "Foldable"];
    "Applicative" = ["Functor"];
    "Monad"      = ["Applicative"];
    "Semigroup"  = [];
    "Monoid"     = ["Semigroup"];
  };

  # 检查 c1 是否是 c2 的超类（传递闭包）
  # Type: AttrSet -> String -> String -> Bool
  isSuperclassOf = graph: super: sub:
    let supers = graph.${sub} or []; in
    builtins.elem super supers
    || lib.any (isSuperclassOf graph super) supers;

}
