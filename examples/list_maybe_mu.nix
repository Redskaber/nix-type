# examples/list_maybe_mu.nix  —  Phase 2
# 综合示例：μ-types + HKT + Row Polymorphism
#
# 展示：
#   1. List a 通过 μ-type 编码（equi-recursive）
#   2. Maybe a 的 ADT + Pattern matching
#   3. State a s = s → (a, s) 通过 HKT 编码
#   4. Row-polymorphic record（开放 record 类型）
#   5. Functor / Applicative typeclass 示例
{ lib }:

let
  typeSystem = import ../lib/default.nix { inherit lib; };

  inherit (typeSystem)
    mkTypeDefault mkTypeWith KStar KStar1 KStar2 KHO1
    rPrimitive rVar rLambda rApply rFn rConstructor rADT rConstrained rMu
    rRecord rVariantRow rRowExtend rRowEmpty rVarDB
    mkVariant normalize typeHash typeEq
    deBruijnify
    mkClass mkEquality
    emptyInstanceDB register resolve withBuiltinInstances
    ;

  # ══════════════════════════════════════════════════════════════════════════════
  # 基础类型
  # ══════════════════════════════════════════════════════════════════════════════

  tInt    = mkTypeDefault (rPrimitive "Int")    KStar;
  tBool   = mkTypeDefault (rPrimitive "Bool")   KStar;
  tString = mkTypeDefault (rPrimitive "String") KStar;
  tUnit   = mkTypeDefault (rPrimitive "Unit")   KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Example 1：List a（μ-type 编码）
  # List a = μ(L). Nil | Cons a L
  # ══════════════════════════════════════════════════════════════════════════════

  # μ-body：Nil | Cons a L（L 是自引用变量）
  listBodyRepr = a: rADT [
    (mkVariant "Nil"  [] 0)
    (mkVariant "Cons" [a (mkTypeDefault (rVar "L") KStar)] 1)
  ] false;

  # List 构造器：* → *
  # List = Λa. μ(L). Nil | Cons a L
  mkList = a:
    mkTypeDefault
      (rMu "L" (mkTypeDefault (listBodyRepr a) KStar))
      KStar;

  listInt    = mkList tInt;
  listBool   = mkList tBool;
  listString = mkList tString;

  # ══════════════════════════════════════════════════════════════════════════════
  # Example 2：Maybe a（ADT + Pattern，无 μ 自引用）
  # Maybe a = Nothing | Just a
  # ══════════════════════════════════════════════════════════════════════════════

  mkMaybe = a:
    mkTypeDefault
      (rADT [
        (mkVariant "Nothing" []  0)
        (mkVariant "Just"    [a] 1)
      ] true)
      KStar;

  maybeInt    = mkMaybe tInt;
  maybeString = mkMaybe tString;

  # ══════════════════════════════════════════════════════════════════════════════
  # Example 3：Either a b（ADT）
  # Either a b = Left a | Right b
  # ══════════════════════════════════════════════════════════════════════════════

  mkEither = a: b:
    mkTypeDefault
      (rADT [
        (mkVariant "Left"  [a] 0)
        (mkVariant "Right" [b] 1)
      ] true)
      KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Example 4：HKT — Functor constraint
  # Functor f ⟹ fmap : (a → b) → f a → f b
  # ══════════════════════════════════════════════════════════════════════════════

  # f : * → *（类型变量，KStar1）
  tF = mkTypeDefault (rVar "f") KStar1;
  tA = mkTypeDefault (rVar "a") KStar;
  tB = mkTypeDefault (rVar "b") KStar;

  # fmap type: (a → b) → f a → f b
  fmapType =
    mkTypeDefault
      (rConstrained
        (mkTypeDefault
          (rFn
            (mkTypeDefault (rFn tA tB) KStar)
            (mkTypeDefault
              (rFn
                (mkTypeDefault (rApply tF [tA]) KStar)
                (mkTypeDefault (rApply tF [tB]) KStar))
              KStar))
          KStar)
        [(mkClass "Functor" [tF])])
      KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Example 5：Row Polymorphism
  # { name: String, age: Int | ρ }（开放 record）
  # ══════════════════════════════════════════════════════════════════════════════

  # 开放 record：{ name: String, age: Int | ρ }
  tRho = mkTypeDefault (rVar "rho") KStar;  # 行变量

  openPersonRecord =
    mkTypeDefault
      (rRecord
        { name = tString; age = tInt; }
        tRho)  # 开放：允许额外字段
      KStar;

  # 封闭 record：{ name: String, age: Int }
  closedPersonRecord =
    mkTypeDefault
      (rRecord
        { name = tString; age = tInt; }
        null)  # 封闭
      KStar;

  # VariantRow（open variant / extensible sum type）
  openColorVariant =
    mkTypeDefault
      (rVariantRow
        { Red = tUnit; Green = tUnit; Blue = tUnit; }
        tRho)  # 可扩展
      KStar;

  # ══════════════════════════════════════════════════════════════════════════════
  # Example 6：State monad（HKT 高阶类型）
  # State s a = s → (a, s)
  # ══════════════════════════════════════════════════════════════════════════════

  tS = mkTypeDefault (rVar "s") KStar;

  # State s a = s → Pair a s
  mkPair = a: b:
    mkTypeDefault
      (rADT [(mkVariant "Pair" [a b] 0)] true)
      KStar;

  mkState = s: a:
    mkTypeDefault
      (rFn s (mkPair a s))
      KStar;

  stateIntInt = mkState tInt tInt;

  # ══════════════════════════════════════════════════════════════════════════════
  # Example 7：de Bruijn canonicalization
  # λa. λb. a  ≡  λx. λy. x（α-equivalence）
  # ══════════════════════════════════════════════════════════════════════════════

  # λa. λb. a
  t_lam_a_b_a =
    mkTypeDefault
      (rLambda "a"
        (mkTypeDefault
          (rLambda "b"
            (mkTypeDefault (rVar "a") KStar))
          KStar))
      (import ../core/kind.nix { inherit lib; }).KStar1;

  # λx. λy. x
  t_lam_x_y_x =
    mkTypeDefault
      (rLambda "x"
        (mkTypeDefault
          (rLambda "y"
            (mkTypeDefault (rVar "x") KStar))
          KStar))
      (import ../core/kind.nix { inherit lib; }).KStar1;

  # α-equivalent via de Bruijn：两者 hash 应相同
  db_a = deBruijnify t_lam_a_b_a;
  db_x = deBruijnify t_lam_x_y_x;

  # ══════════════════════════════════════════════════════════════════════════════
  # Instance Database 示例
  # ══════════════════════════════════════════════════════════════════════════════

  baseDB = emptyInstanceDB;

  # 注册 Eq Int
  db1 = register baseDB "Eq" tInt { eq = x: y: x == y; } [];
  # 注册 Eq Bool
  db2 = register db1 "Eq" tBool { eq = x: y: x == y; } [];
  # 注册 Functor Maybe
  db3 = register db2 "Functor"
    (mkTypeDefault (rConstructor "Maybe" KStar1 ["a"] (rVar "MaybeBody")) KStar1)
    { fmap = f: m: if m == null then null else f m; }
    [];

  # ══════════════════════════════════════════════════════════════════════════════
  # 测试断言
  # ══════════════════════════════════════════════════════════════════════════════

in {

  # 基本类型
  inherit tInt tBool tString tUnit;

  # μ-types
  inherit listInt listBool listString;

  # ADT
  inherit maybeInt maybeString;
  eitherIntString = mkEither tInt tString;

  # HKT
  inherit fmapType stateIntInt;

  # Row types
  inherit openPersonRecord closedPersonRecord openColorVariant;

  # de Bruijn α-equivalence
  alphaEquiv = {
    t1 = db_a;
    t2 = db_x;
    # 这两个应该 hash 相同（α-equivalent）
    hash1 = typeHash db_a;
    hash2 = typeHash db_x;
    areEqual = typeEq db_a db_x;
  };

  # Instance resolution
  instanceTests = {
    eqIntResolved = resolve db3 "Eq" [tInt];
    eqBoolResolved = resolve db3 "Eq" [tBool];
    functorMaybeResolved = resolve db3 "Functor"
      [(mkTypeDefault (rConstructor "Maybe" KStar1 ["a"] (rVar "MB")) KStar1)];
  };

  # 测试：list 的 hash 稳定性
  hashTests = {
    listIntHash  = typeHash listInt;
    listBoolHash = typeHash listBool;
    sameListHash = typeHash listInt == typeHash (mkList tInt);  # 幂等性
  };

  # 不变量验证
  invariantCheck = (import ../lib/default.nix { inherit lib; }).verifyInvariants {};
}
