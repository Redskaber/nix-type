# constraint/ir.nix — Phase 3.1
# Constraint IR（INV-6 内嵌于 TypeRepr）
#
# Phase 3.1 关键修复：
#   INV-C1: constraintKey 用 canonical ids（不依赖 toJSON 顺序）
#   INV-C2: constraintsHash 去重 + 稳定排序（O(n) dedup via AttrSet）
#   INV-C3: mapTypesInConstraint 完整递归（不只顶层）
#   INV-C4: mkImplies 内 sort premises，normalizeConstraint 幂等
#   新增：   canonical pipeline = normalizeConstraint ∘ mapTypesInConstraint
#            constraintId（canonical string key for caching）
#            Class graph 超类方向修正
#
# 不变量：
#   INV-C1: constraintKey = canonical string，不依赖属性顺序
#   INV-C2: constraints list 去重后 hash 稳定
#   INV-C3: mapTypesInConstraint 递归到所有 subtype 位置
#   INV-C4: normalizeConstraint 幂等（normalize ∘ normalize = normalize）
{ lib, typeLib, hashLib }:

let
  inherit (typeLib) isType;
  inherit (hashLib) typeHash;

in rec {

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraint IR（INV-6：必须是 AttrSet，不是函数）
  # ══════════════════════════════════════════════════════════════════════════════

  # Class { className: String; args: [Type] }
  mkClass = className: args: {
    __constraintTag = "Class";
    name = className;
    inherit args;
  };

  # Equality { a: Type; b: Type }（归一化：a.id ≤ b.id）
  mkEquality = a: b:
    let
      # INV-EQ canonical：小 id 在左（symmetric equality）
      ordered = if (a.id or "") <= (b.id or "") then { inherit a b; } else { a = b; b = a; };
    in {
      __constraintTag = "Equality";
      a = ordered.a;
      b = ordered.b;
    };

  # Predicate { fn: String; arg: Type }（Liquid Types 谓词）
  mkPredicate = fn: arg: {
    __constraintTag = "Predicate";
    inherit fn arg;
  };

  # Implies { premises: [Constraint]; conclusion: Constraint }
  # Phase 3.1 修复：premises 在构造时排序（INV-C4）
  mkImplies = premises: conclusion: {
    __constraintTag = "Implies";
    # 稳定排序 premises（INV-C4：规范化）
    premises = lib.sort (a: b: constraintKey a < constraintKey b) premises;
    inherit conclusion;
  };

  # ── 判断 ──────────────────────────────────────────────────────────────────────
  isConstraint = c:
    builtins.isAttrs c && c ? __constraintTag;
  isClass      = c: isConstraint c && c.__constraintTag == "Class";
  isEquality   = c: isConstraint c && c.__constraintTag == "Equality";
  isPredicate  = c: isConstraint c && c.__constraintTag == "Predicate";
  isImplies    = c: isConstraint c && c.__constraintTag == "Implies";

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraint Key（INV-C1：canonical，不依赖 toJSON 属性顺序）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：使用 canonical type ids（INV-T2 保证 ids 稳定）
  # Type: Constraint -> String
  constraintKey = c:
    let tag = c.__constraintTag or "?"; in
    if tag == "Class" then
      let argIds = builtins.concatStringsSep "," (map (a: a.id or "?") (c.args or [])); in
      "cls:${c.name or "?"}:[${argIds}]"
    else if tag == "Equality" then
      # ids 已在 mkEquality 中排序（INV-C1）
      "eq:${(c.a or {}).id or "?"},${(c.b or {}).id or "?"}"
    else if tag == "Predicate" then
      "pred:${c.fn or "?"}:${(c.arg or {}).id or "?"}"
    else if tag == "Implies" then
      let
        premKeys = builtins.concatStringsSep "," (map constraintKey (c.premises or []));
      in
      "impl:[${premKeys}]→${constraintKey (c.conclusion or {})}"
    else "c:?";

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraint Normalization（INV-C4：幂等统一入口）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：
  #   canonical pipeline = mapTypesInConstraint f → normalizeConstraint
  #   ordering invariant: ALWAYS subst before normalize
  #
  # Type: Constraint -> Constraint
  normalizeConstraint = c:
    let tag = c.__constraintTag or null; in
    if tag == "Class" then
      # sort args by id（canonical）
      c // { args = lib.sort (a: b: (a.id or "") < (b.id or "")) (c.args or []); }
    else if tag == "Equality" then
      # re-apply ordering（idempotent）
      mkEquality (c.a or c) (c.b or c)
    else if tag == "Implies" then
      # re-sort premises（idempotent）
      c // {
        premises = lib.sort (a: b: constraintKey a < constraintKey b) (c.premises or []);
        conclusion = normalizeConstraint (c.conclusion or c);
      }
    else c;

  # ══════════════════════════════════════════════════════════════════════════════
  # mapTypesInConstraint（INV-C3：完整递归替换）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：递归到所有 subtype 位置（不只顶层）
  # Type: (Type -> Type) -> Constraint -> Constraint
  mapTypesInConstraint = f: c:
    let tag = c.__constraintTag or null; in
    if tag == "Class" then
      c // { args = map f (c.args or []); }
    else if tag == "Equality" then
      # 替换后重新构造（保证 mkEquality 的 canonical ordering）
      mkEquality (f (c.a or c)) (f (c.b or c))
    else if tag == "Predicate" then
      c // { arg = if c ? arg then f c.arg else null; }
    else if tag == "Implies" then
      c // {
        premises   = map (mapTypesInConstraint f) (c.premises or []);
        conclusion = mapTypesInConstraint f (c.conclusion or c);
      }
    else c;

  # ── canonical pipeline（Phase 3.1：统一入口）─────────────────────────────────
  # Phase 3.1: ALWAYS substitute before normalize（ordering invariant）
  # Type: (Type -> Type) -> Constraint -> Constraint
  applyAndNormalize = f: c:
    normalizeConstraint (mapTypesInConstraint f c);

  # ══════════════════════════════════════════════════════════════════════════════
  # Constraints Hash（INV-C2：去重 + 稳定排序）
  # ══════════════════════════════════════════════════════════════════════════════

  # Phase 3.1 修复：O(n) dedup via AttrSet（不是 O(n²) list comparison）
  # Type: [Constraint] -> [Constraint]
  deduplicateConstraints = cs:
    let
      go = acc: seen: cs:
        if cs == [] then acc
        else
          let
            c   = builtins.head cs;
            rest = builtins.tail cs;
            key = constraintKey c;
          in
          if seen ? ${key} then go acc seen rest
          else go (acc ++ [c]) (seen // { ${key} = true; }) rest;
    in
    go [] {} cs;

  # Sorted canonical constraints（dedup + sort by key）
  # Type: [Constraint] -> [Constraint]
  canonicalizeConstraints = cs:
    let
      deduped = deduplicateConstraints cs;
    in
    lib.sort (a: b: constraintKey a < constraintKey b) deduped;

  # Hash of constraint list（canonical）
  # Type: [Constraint] -> String
  constraintsHash = cs:
    let
      canonical = canonicalizeConstraints cs;
      keys = builtins.concatStringsSep ";" (map constraintKey canonical);
    in
    builtins.hashString "sha256" keys;

  # ══════════════════════════════════════════════════════════════════════════════
  # Class Graph（超类关系，Phase 3.1 修复：方向明确）
  # ══════════════════════════════════════════════════════════════════════════════

  # ClassGraph = AttrSet ClassName ClassDef
  # ClassDef = { supers: [ClassName]; methods: AttrSet MethodName Type }

  mkClass_ = className: supers: methods:
    { inherit supers methods; };

  defaultClassGraph = {
    "Eq"     = mkClass_ "Eq"     []        { eq = null; neq = null; };
    "Ord"    = mkClass_ "Ord"    ["Eq"]    { compare = null; lt = null; le = null; gt = null; ge = null; };
    "Show"   = mkClass_ "Show"   []        { show = null; };
    "Num"    = mkClass_ "Num"    ["Eq"]    { add = null; sub = null; mul = null; abs = null; negate = null; fromInt = null; };
    "Enum"   = mkClass_ "Enum"   []        { toEnum = null; fromEnum = null; };
    "Bounded" = mkClass_ "Bounded" []     { minBound = null; maxBound = null; };
    "Semigroup" = mkClass_ "Semigroup" [] { append = null; };
    "Monoid" = mkClass_ "Monoid" ["Semigroup"] { mempty = null; };
    "Functor" = mkClass_ "Functor" []     { fmap = null; };
    "Foldable" = mkClass_ "Foldable" []   { foldr = null; foldl = null; };
    "Traversable" = mkClass_ "Traversable" ["Functor" "Foldable"] { traverse = null; };
  };

  # Phase 3.1 修复：isSuperclassOf 方向明确
  # isSuperclassOf graph super sub → "super 是 sub 的 superclass"
  # i.e. sub <: super（sub 继承自 super）
  # Type: ClassGraph -> ClassName -> ClassName -> Bool
  isSuperclassOf = graph: super: sub:
    let
      subDef = graph.${sub} or null;
    in
    if subDef == null then false
    else
      builtins.elem super (subDef.supers or [])
      || lib.any (parent: isSuperclassOf graph super parent) (subDef.supers or []);

  # 获取 className 的所有 superclasses（传递闭包）
  # Type: ClassGraph -> ClassName -> [ClassName]
  getAllSupers = graph: className:
    let
      def   = graph.${className} or null;
      directs = if def == null then [] else def.supers or [];
      transitive = builtins.concatMap (getAllSupers graph) directs;
    in
    lib.unique (directs ++ transitive);

  # 获取 className 的所有 subclasses（反向查询）
  # Type: ClassGraph -> ClassName -> [ClassName]
  getAllSubs = graph: className:
    builtins.filter
      (name: isSuperclassOf graph className name)
      (builtins.attrNames graph);

}
