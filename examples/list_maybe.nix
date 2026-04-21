# examples/list_maybe.nix
# Phase 1 — List + Maybe 综合示例
# 演示：Constructor, ADT, Apply, Constrained, Pattern 全链路
{ lib ? (import <nixpkgs> {}).lib }:

let
  ts = import ../lib/default.nix { inherit lib; };
  inherit (ts.api)
    rPrimitive rVar rLambda rApply rConstructor rFn rADT rConstrained
    mkVariant mkType mkTypeDefault mkTypeWith KStar KArrow KStar1 KStar2
    defaultMeta alphaMeta
    mkClass mkEquality mkImplies
    normalize typeHash typeEq
    solveDefault unifyFresh
    mkPatternConstructor mkPatternVar patternWildcard
    compilePatterns matchType checkExhaustiveness;
  inherit (ts.typeLib) mkBootstrapType isType;
  inherit (ts.kindLib) KUnbound;

  # ══════════════════════════════════════════════════════════════════════════════
  # 基础类型
  # ══════════════════════════════════════════════════════════════════════════════

  tInt    = mkTypeDefault (rPrimitive "Int")    KStar;
  tBool   = mkTypeDefault (rPrimitive "Bool")   KStar;
  tString = mkTypeDefault (rPrimitive "String") KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Maybe a = Nothing | Just a
  # Kind: * -> *
  # ══════════════════════════════════════════════════════════════════════════════

  tAVar = mkTypeDefault (rVar "a" "_maybe") KStar;

  tMaybeBody = mkTypeDefault
    (rADT [
      (mkVariant "Nothing" [] 0)
      (mkVariant "Just"    [ tAVar ] 1)
    ] true)
    KStar;

  tMaybe = mkTypeDefault
    (rConstructor "Maybe" KStar1 [ "a" ] tMaybeBody)
    KStar1;

  # Maybe Int
  tMaybeInt = mkTypeDefault (rApply tMaybe [ tInt ]) KStar;
  tMaybeIntNF = normalize 128 tMaybeInt;

  # ══════════════════════════════════════════════════════════════════════════════
  # List a = Nil | Cons a (List a)
  # Kind: * -> *
  # Note: 递归类型，用 Constructor 自引用
  # ══════════════════════════════════════════════════════════════════════════════

  tBVar = mkTypeDefault (rVar "a" "_list") KStar;

  # 注意：List a 的 Cons 字段包含 List a（自递归）
  # 简化：在此用 Var "List" 表示自引用（Phase 2: μ-types）
  tListSelf = mkTypeDefault (rVar "List" "_list_self") KStar1;
  tListSelfApp = mkTypeDefault (rApply tListSelf [ tBVar ]) KStar;

  tListBody = mkTypeDefault
    (rADT [
      (mkVariant "Nil"  [] 0)
      (mkVariant "Cons" [ tBVar tListSelfApp ] 1)
    ] true)
    KStar;

  tList = mkTypeDefault
    (rConstructor "List" KStar1 [ "a" ] tListBody)
    KStar1;

  # List Int
  tListInt = mkTypeDefault (rApply tList [ tInt ]) KStar;
  tListIntNF = normalize 64 tListInt;  # fuel 小一些，避免递归展开过深

  # ══════════════════════════════════════════════════════════════════════════════
  # Either a b = Left a | Right b
  # Kind: * -> * -> *
  # ══════════════════════════════════════════════════════════════════════════════

  tAVar2 = mkTypeDefault (rVar "a" "_either") KStar;
  tBVar2 = mkTypeDefault (rVar "b" "_either") KStar;

  tEitherBody = mkTypeDefault
    (rADT [
      (mkVariant "Left"  [ tAVar2 ] 0)
      (mkVariant "Right" [ tBVar2 ] 1)
    ] true)
    KStar;

  tEither = mkTypeDefault
    (rConstructor "Either" KStar2 [ "a" "b" ] tEitherBody)
    KStar2;

  # Either Int Bool
  tEitherIntBool = mkTypeDefault (rApply tEither [ tInt tBool ]) KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Constrained 示例：(Eq a, Ord a) => a
  # ══════════════════════════════════════════════════════════════════════════════

  tAVarC = mkTypeDefault (rVar "a" "_c") KStar;
  tConstrainedA = mkTypeDefault
    (rConstrained tAVarC [
      (mkClass "Eq" [ tAVarC ])
      (mkClass "Ord" [ tAVarC ])
    ])
    KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Pattern Matching 示例：match Maybe Int
  # ══════════════════════════════════════════════════════════════════════════════

  maybeClauses = [
    {
      pat    = mkPatternConstructor "Nothing" [];
      action = "got Nothing";
    }
    {
      pat    = mkPatternConstructor "Just" [ (mkPatternVar "x") ];
      action = "got Just";
    }
  ];

  maybeDTree = compilePatterns maybeClauses;

  # ══════════════════════════════════════════════════════════════════════════════
  # Unification 示例
  # ══════════════════════════════════════════════════════════════════════════════

  # unify (Maybe a) (Maybe Int) → a = Int
  aVarUnify = mkTypeDefault (rVar "a" "_unify") KStar;
  tMaybeA   = mkTypeDefault (rApply tMaybe [ aVarUnify ]) KStar;
  unifyResult = unifyFresh tMaybeA tMaybeInt;

  # ══════════════════════════════════════════════════════════════════════════════
  # Solver 示例
  # ══════════════════════════════════════════════════════════════════════════════

  solverResult = solveDefault [
    (mkClass "Eq"  [ tInt ])
    (mkClass "Ord" [ tInt ])
    (mkClass "Num" [ tInt ])
  ];

  # ══════════════════════════════════════════════════════════════════════════════
  # 输出报告
  # ══════════════════════════════════════════════════════════════════════════════

in {
  # 类型构造验证
  types = {
    maybe_is_type      = isType tMaybe;
    maybe_int_is_type  = isType tMaybeInt;
    list_is_type       = isType tList;
    list_int_is_type   = isType tListInt;
    either_is_type     = isType tEither;
    constrained_is_type = isType tConstrainedA;
  };

  # Normalize 验证
  normalize_results = {
    maybe_int_nf_variant  = tMaybeIntNF.repr.__variant or "?";
    list_int_fuel_ok      = isType tListIntNF;
    constrained_a_kind    = tConstrainedA.kind.__kindVariant or "?";
  };

  # Hash 验证（INV-4）
  hashes = {
    int_hash   = typeHash tInt;
    bool_hash  = typeHash tBool;
    int_eq_int = (typeHash tInt) == (typeHash tInt);
    int_ne_bool = (typeHash tInt) != (typeHash tBool);
    maybe_int_hash = typeHash tMaybeIntNF;
  };

  # Equality 验证
  equality = {
    int_eq_int  = typeEq tInt tInt;
    int_ne_bool = !typeEq tInt tBool;
  };

  # Pattern matching 验证
  pattern = {
    dtree_compiled = maybeDTree.__dtTag or "?";
    exhaustive     = (checkExhaustiveness tMaybeIntNF
                       (map (c: c.pat) maybeClauses)).exhaustive;
  };

  # Unification 验证
  unification = {
    ok            = unifyResult.ok;
    a_bound_to    = (unifyResult.subst.a or { repr = { name = "?"; }; }).repr.name or "?";
  };

  # Solver 验证
  solver = {
    ok            = solverResult.ok;
    class_residual = builtins.length solverResult.classResidual;
  };
}
