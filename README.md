# nix-types — Phase 4.5.9

**Pure Nix Native Type System** — System Fω-level expressiveness, implemented entirely in
pure Nix with no external runtime dependencies.

[![Phase](https://img.shields.io/badge/phase-4.5.9-blue)]()
[![Tests](https://img.shields.io/badge/tests-203%2F203-brightgreen)]()
[![INVs](https://img.shields.io/badge/invariants-45%2B-orange)]()

---

## 快速开始

```bash
# 运行全部 203 个测试
nix run .#test

# 运行端到端演示（8 个场景）
nix run .#demo

# 检查架构不变量
nix run .#check-invariants

# 详细失败诊断（0 失败则输出 ok）
nix run .#diagnose
```

### 当前输出（v4.5.9）

```
nix run .#test
{"failed":[],"groups":[],"ok":true,"passed":203,"summary":"Passed: 203 / 203","total":203}

nix run .#demo
{"all":true,"s1_adt":true,"s2_solver":true,"s3_modules":true,"s4_refined":true,
 "s5_effects":true,"s6_bidir":true,"s7_kind":true,"s8_handler":true}

nix run .#check-invariants
{"inv4":true,"inv6":true,"inv8":true,"invBidir2":true,"invBidir3":true,
 "invKind1":true,"invKind2":true,"invKind3":true,"invMu1":true,
 "invPat1":true,"invPat3":true,"version":"4.5.9"}
```

---

## 特性概览

| 特性                       | 状态 | INV                | 说明                                           |
| -------------------------- | ---- | ------------------ | ---------------------------------------------- |
| TypeIR 统一宇宙            | ✅   | INV-1              | `Type = { tag; id; kind; repr; meta }`         |
| Kind 系统（5 种）          | ✅   | INV-KIND-1/2/3     | KStar/KArrow/KRow/KEffect/KVar + fixpoint      |
| TRS 规则集（11 规则）      | ✅   | INV-2              | β-reduction, row canonical, constraint merge…  |
| 约束 IR（11 种）           | ✅   | INV-6              | Eq/Class/Row/Refined/Scheme/Kind/Sub/HasField… |
| Constraint Solver          | ✅   | INV-SOL5           | Worklist + fuel-bounded (DEFAULT_FUEL=2000)    |
| UnifiedSubst               | ✅   | INV-US1~5          | type+row+kind compose 律                       |
| Robinson Unification       | ✅   | INV-MU-1           | occurs check + Mu bisim up-to congruence       |
| Row Polymorphism           | ✅   | INV-ROW            | RowExtend + VariantRow + open tail             |
| ADT + Pattern Match        | ✅   | INV-PAT-1/2        | Decision Tree O(1) ordinal dispatch            |
| Nested Record Pattern      | ✅   | INV-PAT-3          | patternVars 递归子模式                         |
| Mu equi-recursive          | ✅   | INV-MU-1           | coinductive bisimulation                       |
| Bidirectional Typechecking | ✅   | INV-BIDIR-1/2/3    | infer + check + HM let-gen                     |
| Effect Handlers            | ✅   | INV-EFF-4~11       | deep/shallow handlers + continuations          |
| Module System              | ✅   | INV-MOD-1~8        | Sig/Struct/ModFunctor/composeFunctors          |
| Refined Types              | ✅   | INV-REFINED        | SMT oracle bridge (静态求值 + stub)            |
| Salsa QueryDB + Memo       | ✅   | INV-G1~4, INV-TOPO | BFS 失效传播，epoch-based memo                 |
| Serialization 边界         | ✅   | INV-SER-1          | `builtins.toJSON` 从不碰 Type/函数值           |
| TypeRepr 宇宙（26+ 变体）  | ✅   | —                  | 含 rDynamic/rHole/rTypeScheme/rComposedFunctor |

---

## 项目结构

```
nix-types/
├── core/
│   ├── kind.nix          # Kind 系统 + inferKind + fixpoint solver
│   ├── type.nix          # TypeIR 宇宙 + mkScheme + _mkId
│   └── meta.nix          # MetaType 控制层（eqStrategy, muPolicy）
├── repr/
│   └── all.nix           # TypeRepr 26+ 变体构造器
├── normalize/
│   ├── rewrite.nix       # TRS 主引擎（fuel-based）
│   ├── rules.nix         # 11 条 TRS 改写规则
│   ├── substitute.nix    # capture-safe 同步替换
│   └── unified_subst.nix # UnifiedSubst（type+row+kind）
├── constraint/
│   ├── ir.nix            # Constraint IR（11 种约束构造器）
│   ├── unify.nix         # Robinson + Mu bisim
│   ├── unify_row.nix     # Row 行等式合一
│   └── solver.nix        # Worklist solver（燃料有界）
├── meta/
│   ├── serialize.nix     # de Bruijn 规范序列化（INV-SER-1 核心）
│   ├── hash.nix          # 规范 hash（_safeStr 保护）
│   └── equality.nix      # typeEq via NF-hash
├── runtime/
│   └── instance.nix      # Instance DB + 全局一致性检查
├── refined/
│   └── types.nix         # 精化类型 + SMT oracle
├── effect/
│   └── handlers.nix      # Effect 处理器 + continuations
├── bidir/
│   └── check.nix         # 双向类型检查 + HM let-gen
├── match/
│   └── pattern.nix       # Pattern IR + Decision Tree
├── incremental/
│   ├── graph.nix         # 依赖图（BFS 失效传播）
│   ├── memo.nix          # Memo 层（epoch-based）
│   └── query.nix         # QueryDB（Salsa-style）
├── module/
│   └── system.nix        # Sig/Struct/ModFunctor
├── lib/
│   └── default.nix       # 280+ 导出（Layer 0~22 拓扑顺序）
├── testlib/
│   └── default.nix       # 测试框架（mkTestBool/Eq/Eval/Error/With）
├── tests/
│   ├── test_all.nix      # 203 测试，28 组
│   └── match/
│       └── diagnose_pat.nix  # Pattern 专项诊断
└── examples/
    └── demo.nix          # 8 个端到端场景
```

---

## API 速查

### core/kind.nix — Kind 系统

```nix
KStar                             # 值类型 Kind：*
KArrow from to                    # 类型构造器 Kind：κ₁ → κ₂
KRow                              # Row Kind
KEffect                           # Effect Row Kind
KVar name                         # Kind 变量（用于推断）
KUnbound                          # 未绑定占位（推断中间态）

isKind k                          # k 是否为合法 Kind
isKUnbound k                      # k 是否为 Unbound
serializeKind k                   # Kind → 规范字符串（INV-SER-1）
kindEq a b                        # Kind 等价比较
kindArity k                       # Kind 参数数量
applyKind fnKind argKind          # Kind 应用
applyKindSubst ksubst k           # 代入 Kind 变量
unifyKind a b                     # Kind 合一 → { ok; subst }
kindFreeVars k                    # Kind 自由变量集
composeKindSubst s2 s1            # Kind 代入复合（s2 ∘ s1）
mergeKindEnv envA envB            # 合并 Kind 环境
inferKind kenv repr               # 推断 TypeRepr 的 Kind
inferKindWithAnnotation kenv repr ann   # 带注解的 Kind 推断
checkKindAnnotation inferred ann  # 验证推断与注解一致
solveKindConstraints kcs          # 单遍 Kind 约束求解
solveKindConstraintsFixpoint kcs  # 不动点 Kind 约束求解（max 10 iter, INV-KIND-3）
checkKindAnnotationFixpoint kcs   # 不动点后验证注解一致性
inferKindWithAnnotationFixpoint kenv repr ann  # 完整推断+注解+不动点
defaultKinds                      # 内建类型名 → Kind 映射
```

### core/type.nix — TypeIR

```nix
mkTypeWith repr kind meta         # 完整 Type 构造
mkTypeDefault repr kind           # 带 defaultMeta 的 Type 构造
isType t                          # 谓词：t 是 Type 对象
typeRepr t                        # 提取 repr（assert isType）
typeKind t                        # 提取 kind（assert isType）
typeMeta t                        # 提取 meta（assert isType）
withRepr t newRepr                # 替换 repr（保留 kind/meta）
withKind t newKind                # 替换 kind
withMeta t newMeta                # 替换 meta
tPrim name                        # 原始类型：{ tag="Type"; repr=rPrimitive name; ... }
tString / tInt / tBool / tUnit    # 内建原始类型别名
mkScheme forall body constraints  # 类型模式（HM）
monoScheme t                      # 单态模式（forall=[], cs=[]）
isScheme s                        # 谓词：s 是 Scheme
schemeForall s                    # 提取 forall 变量列表
freeVars t                        # Type 自由类型变量集
```

### core/meta.nix — MetaType

```nix
defaultMeta                       # 默认元信息（structural, guardset）
mkMeta overrides                  # 覆盖默认字段构造 Meta
nominalMeta                       # 名义等价策略 Meta
isStructural m                    # m.eqStrategy == "structural"
isBisimCongruence m               # m.muPolicy == "bisim-congruence"
mergeMeta m1 m2                   # 合并两个 Meta（右优先）
```

### repr/all.nix — TypeRepr 变体（26+）

```nix
rPrimitive name                   # 原始类型名
rVar name                         # 类型变量（自由）
rVarScoped name scope             # 类型变量（带 scope）
rLambda param body                # 类型 λ（type-level）
rApply fn args                    # 类型应用
rConstructor name kind params body  # 参数化构造器
rFn from to                       # 函数类型 from → to
rADT variants closed              # 代数数据类型（closed/open）
rConstrained base constraints     # 约束类型
rMu var body                      # 等递归类型 μ
rPi param paramType body          # 依赖函数 Π
rSigma param paramType body       # 依赖积 Σ
rRecord fields                    # 记录类型（fields: attrset）
rRowExtend label ty tail          # Row 扩展
rRowEmpty                         # 空 Row
rVariantRow variants tail         # Variant Row（open/closed）
rEffect effectRow resultType      # Effect 类型
rEffectMerge e1 e2                # Effect Row 合并
rHandler effectTag branches returnType  # Handler 类型
rRefined base predVar predExpr    # 精化类型
rSig fields                       # 模块签名
rStruct sig impls                 # 模块结构体
rModFunctor param paramSig body   # 模块函子
rOpaque inner tag                 # 不透明封装
rForall vars body                 # 全称量化（多变量）
rForAll name kind body            # 全称量化（单变量带 Kind）
rDynamic                          # 渐进类型 Dynamic（rGradual）
rHole holeId                      # 待填孔洞
rComposedFunctor                  # 组合函子（f ∘ g）
rTypeScheme var kind body         # 类型模式（rForAll 别名变体）
rTyCon name kind                  # 类型构造器名
```

### meta/serialize.nix — 规范序列化（INV-SER-1）

```nix
serializeKind k                   # Kind → 规范字符串（已在 kindLib）
serializeConstraint c             # Constraint → 规范字符串（纯数据）
serializePredExpr pe              # PredExpr → 规范字符串
serializeRepr r                   # TypeRepr → de Bruijn 规范字符串
serializeType t                   # Type → 规范字符串（取 t.repr）
```

### meta/hash.nix — Hash

```nix
typeHash t                        # Type → SHA256 hash string
reprHash r                        # TypeRepr → hash
constraintHash c                  # Constraint → hash
schemeHash s                      # Scheme → hash
hashConsEq a b                    # typeHash 等价比较
substHash subst                   # Subst → hash
```

### meta/equality.nix — 类型等价

```nix
typeEq a b                        # Type 等价（NF-hash）
typeEqN normalizeLib a b          # 带自定义 normalize 的等价
kindEq a b                        # Kind 等价（结构递归）
constraintEq a b                  # Constraint 等价
schemeEq a b                      # Scheme 等价
isSubtype a b                     # 子类型谓词（当前：typeEq）
alphaEq                           # = typeEq（α-等价别名）
```

### constraint/ir.nix — Constraint IR

```nix
mkEqConstraint lhs rhs            # lhs ~ rhs
mkClassConstraint className args  # C args
mkPredConstraint predName subject # predName(subject)
mkImpliesConstraint premises concl  # premises ⊢ conclusion
mkRowEqConstraint lhsRow rhsRow   # row lhs ~ row rhs
mkRefinedConstraint subject predVar predExpr  # {v:B | P}
mkSchemeConstraint scheme ty      # scheme ≤ ty（实例化）
mkKindConstraint typeVar expectedKind  # var :: κ
mkInstanceConstraint className types   # instance C types
mkSubConstraint sub sup           # sub <: sup
mkHasFieldConstraint field fieldType recType  # {field:T} ∈ R

# PredExpr 构造器
mkPFalse                          # ⊥
mkPVar name                       # 谓词变量（注：区别于 patternLib.mkPVar）
mkPNot pe                         # ¬P
mkPAnd p1 p2                      # P₁ ∧ P₂
mkPOr p1 p2                       # P₁ ∨ P₂
mkPGt rhs / mkPGe rhs / mkPLt rhs / mkPLe rhs  # 算术谓词

isConstraint c                    # 谓词
isInstanceConstraint c            # 谓词：Instance 约束
isHasFieldConstraint c            # 谓词：HasField 约束
constraintKey c                   # 规范 key（= serializeConstraint c）
mergeConstraints cs1 cs2          # 合并两个约束列表（去重）
```

### constraint/unify.nix — 合一

```nix
occursIn varName t                # occurs check
unify a b                         # Robinson 合一（含 Mu bisim）→ { ok; subst }
unifyAll pairs                    # [(a,b)] 批量合一
```

### constraint/unify_row.nix — Row 合一

```nix
unifyRow lhsRow rhsRow            # Row 等式合一 → { ok; subst }
```

### constraint/solver.nix — Constraint Solver

```nix
DEFAULT_FUEL                      # = 2000
solve constraints classGraph instanceDB  # 主入口 → SolverResult
solveSimple constraints           # 无 class/instance 的简化入口
getTypeSubst result               # 提取类型代入
getRowSubst result                # 提取 Row 代入
getKindSubst result               # 提取 Kind 代入
mkSolverResult ok subst solved classResidual smtResidual rowSubst  # 构造结果
failResult error                  # 构造失败结果
```

### normalize/substitute.nix — 替换

```nix
substitute x replacement t        # 单变量替换（capture-safe，INV-SUB2）
substituteMany bindings t         # 同步多变量替换
applyUnifiedSubst usubst t        # 应用 UnifiedSubst
substituteParams params args body # 参数列表批量替换
```

### normalize/unified_subst.nix — UnifiedSubst

```nix
emptySubst                        # 空代入
singleTypeBinding name t          # 单类型绑定
singleRowBinding name r           # 单 Row 绑定
singleKindBinding name k          # 单 Kind 绑定
isSubst s                         # 谓词
isEmpty s                         # 谓词
composeSubst f g                  # f ∘ g（INV-US3）
applySubst usubst t               # 应用到 Type
applySubstToConstraint usubst c   # 应用到 Constraint
applySubstToConstraints usubst cs # 批量应用
fromLegacyTypeSubst ts            # 兼容旧 typeSubst 格式
fromLegacyRowSubst rs             # 兼容旧 rowSubst 格式
substDomain s                     # 代入定义域
substRange s                      # 代入值域
```

### normalize/rewrite.nix — TRS 引擎

```nix
DEFAULT_FUEL                      # = 1000
normalizeWithFuel fuel t          # 有燃料归约
normalizeDeep t                   # 深度归约（DEEP_FUEL）
isNormalForm t                    # 谓词：已是 NF
normalizeConstraint c             # 归约约束内的 Type
deduplicateConstraints cs         # 去重约束列表
```

### normalize/rules.nix — TRS 规则

```nix
ruleBetaReduce t                  # β-reduction（rLambda @ rApply）
ruleConstructorPartial t          # 构造器偏应用
ruleConstraintMerge t             # 约束合并
ruleConstraintFloat t             # 约束上浮
ruleRowCanonical t                # Row 规范化
ruleVariantRowCanonical t         # VariantRow 规范化
ruleEffectMerge t                 # Effect 合并
ruleRefined t                     # 精化类型归约
ruleSig t                         # Sig 规范化
ruleRecordCanonical t             # Record 规范化
ruleEffectNormalize t             # Effect 归约
allRules                          # 规则列表（按优先级）
applyFirstRule t                  # 应用第一条匹配规则
```

### bidir/check.nix — 双向类型检查

```nix
# Expr 构造器
eLam param body                   # λ param. body
eLamA param paramTy body          # λ (param:T). body（带注解，INV-BIDIR-2）
eApp fn arg                       # fn arg
eVar name                         # 变量
eLet name rhs body                # let name = rhs in body
eIf cond thenE elseE              # if-then-else
ePrim primType                    # 原始值（带类型）

infer ctx expr                    # 推断 → { type; constraints; ctx }
check ctx expr expectedTy         # 检查 → { ok; constraints }
generalize ctx ty constraints     # HM let-gen → Scheme（INV-SCHEME-1）
checkAnnotatedLam ctx param paramTy body  # 验证注解 λ（INV-BIDIR-2）
checkAppResultSolved ctx fn arg   # 验证 App 结果已求解（INV-BIDIR-3）
```

### effect/handlers.nix — Effect 处理器

```nix
mkHandler effectTag branches returnType     # 基本处理器
mkDeepHandler effectTag branches returnType  # 深处理器
mkShallowHandler effectTag branches returnType  # 浅处理器
mkHandlerWithCont effectTag paramType contType returnType  # 带续体（INV-EFF-11）
mkContType paramType residualEffects returnType  # 续体类型
isHandler t                        # 谓词
isHandlerWithCont t                # 谓词：带续体
emptyEffectRow                     # 空 Effect Row
singleEffect name ty               # 单 Effect
effectMerge e1 e2                  # Effect 行合并
checkHandler handler effectType    # 验证处理器覆盖（→ {ok; ...}）
handleAll handlers effectType      # 批量 handleAll（→ {ok; ...}）
subtractEffect row label           # 从 Row 去除一个 Effect
deepHandlerCovers handler effectType  # 深处理器覆盖检查
shallowHandlerResult handler effectType  # 浅处理器结果类型
checkHandlerContWellFormed handlerCont  # 续体域检查（INV-EFF-11）
checkEffectWellFormed t            # Effect 类型合规性
```

### module/system.nix — 模块系统

```nix
mkSig fields                      # 模块签名：{ name → Type }
isSig t                           # 谓词
mkStruct sig impls                # 模块结构体
isStruct t                        # 谓词
structField struct name           # 提取字段
mkModFunctor param paramSig body  # 模块函子（参数化模块）
isModFunctor t                    # 谓词
applyFunctor functor argStruct    # 应用函子（→ Struct）
composeFunctors f1 f2             # 函子复合（λM. f1(f2(M))）
composeFunctorChain functors      # 函子链复合
sigCompatible sigA sigB           # 签名兼容性（A ⊇ B）
sigMerge sigA sigB                # 签名合并（右优先）
seal t sealTag                    # 不透明封装（模块抽象）
unseal sealed sealTag             # 解封（需匹配 tag）
```

### match/pattern.nix — 模式匹配

```nix
# Pattern 构造器
mkPVar name                       # 变量模式（绑定 name）
mkPLit value                      # 字面量模式
mkPCtor name fields               # 构造器模式（fields: [Pattern]）
mkPWild                           # 通配符
mkPAnd p1 p2                      # And 模式（p1 @ p2）
mkPRecord fields                  # Record 模式（fields: attrset→Pattern）

isPattern p                       # 谓词

patternVars pat                   # [String]：所有绑定变量（INV-PAT-1/3）
patternVarsSet pat                # Set（attrset）：绑定变量集合
isLinear pat                      # Bool：无重复绑定（INV-PAT-2）
patternDepth pat                  # Int：模式树深度
checkPatternVars pat expectedVarsSet  # 验证绑定变量与期望一致

# Match 编译
mkArm pat body                    # { pat; body }
mkDTSwitch scrutinee branches default_  # Decision Tree 节点
compileMatch arms adtVariants     # [Arm] → DTSwitch（O(1) 顺序查找）
checkExhaustive arms adtVariants  # 穷举性检查 → { ok; missing }
```

### runtime/instance.nix — Instance DB

```nix
mkInstance ty ctorName data       # 实例值
isInstance i                      # 谓词
instanceEq a b                    # 实例等价（hash 比较）
instanceData i                    # 提取数据
instanceType i                    # 提取类型
mkInstanceRecord className args impl superclasses  # 实例记录
isInstanceRecord r                # 谓词
emptyDB                           # 空 InstanceDB
registerInstance db record        # 注册实例（→ db）
lookupInstance db className args  # 查找 → InstanceRecord | null
resolveWithFallback classGraph db className args  # 含继承链查找
canDischarge resolveResult        # Bool：已解析且 impl≠null
checkGlobalCoherence db unifyFn   # 全局一致性检查（INV-I1）
mergeLocalInstances global local unifyFn  # 合并 local 到 global
```

### refined/types.nix — 精化类型

```nix
mkRefined base predVar predExpr   # {v:base | P(v)}
isRefined t                       # 谓词
refinedPredVar t                  # 谓词变量名
refinedPredExp t                  # PredExpr
staticEvalPred predVar predExpr value  # 静态求值（Int/Bool 域）
defaultSmtOracle predVar predExpr  # 默认 SMT 桩（always true）
checkRefinedSubtype subTy superTy smtOracle  # 精化子类型检查
normalizeRefined t                # 归约精化类型（static eval）
tPositiveInt / tNonNegInt / tNonEmptyString  # 内建精化类型
```

### incremental/graph.nix — 依赖图

```nix
emptyGraph                        # 空图（{nodes;edges;revEdges}）
addNode graph nodeId              # 添加节点
removeNode graph nodeId           # 删除节点（连边一并删除）
addEdge graph fromId toId         # 添加有向边（from 依赖 to）
removeEdge graph fromId toId      # 删除边
markStale graph nodeId            # 标记过时
markClean graph nodeId            # 标记干净
nodeState graph nodeId            # "clean" | "stale" | "unknown"
isClean graph nodeId              # 谓词
isStale graph nodeId              # 谓词
invalidate graph nodeId           # BFS 失效传播（INV-G1）
topologicalSort graph             # { ok; order; error }（INV-TOPO）
hasCycle graph                    # Bool
reachable graph fromId            # [nodeId]（BFS 可达集）
```

### incremental/memo.nix — Memo 层

```nix
emptyMemo                         # { normalize={}; substitute={}; solve={}; epoch=0 }
storeNormalize memo typeId nf     # 存储归约结果
lookupNormalize memo typeId       # 查找归约结果（null = miss）
storeSubstitute memo key result   # 存储代入结果
lookupSubstitute memo key         # 查找代入结果
storeSolve memo key result        # 存储 solver 结果
lookupSolve memo key              # 查找 solver 结果
bumpEpoch memo                    # epoch +1（使全部缓存失效）
currentEpoch memo                 # 当前 epoch 值
```

### incremental/query.nix — QueryDB（Salsa-style）

```nix
mkQueryKey tag inputs             # 规范 QueryKey（INV-G4）
emptyDB                           # 空 QueryDB（{cache;deps;rdeps}）
storeResult db key value deps     # 存储结果 + 依赖边
lookupResult db key               # null | { value; deps }
invalidateKey db key              # BFS 失效（INV-G1/2）
cacheNormalize db memo typeId nf deps  # 组合 cache+memo 存储
bumpEpochDB state                 # QueryDB epoch 递增
hasDependencyCycle db key         # DFS 环检测
cacheStats db                     # { total; valid; invalid }
```

### testlib/default.nix — 测试框架

```nix
mkTestBool name cond              # Bool 断言（INV-TEST-1/6）
mkTestEq name result expected     # 等值断言（带 diag）
mkTestEval name expr              # 求值断言（expr 不应 eval-error）
mkTestError name cond             # 负面测试（cond 应 false/error）
mkTestWith name cond diagExpr     # Bool 断言 + 诊断表达式（INV-TEST-6）
testGroup name tests              # 组聚合 → {name;passed;total;failed;ok}
runGroups testGroups              # JSON-safe 摘要（INV-TEST-7）
failedGroups testGroups           # 过滤失败组
failedList failedGroups           # 失败列表（INV-TEST-5）
diagnoseAll failedGroups          # 详细诊断（hint/actual/expected）
safeShow v                        # Nix 值 → JSON-safe 字符串
```

---

## Nix 实现约束（核心不变量）

| 不变量     | 规则                                                            |
| ---------- | --------------------------------------------------------------- |
| INV-NIX-1  | `or` 不在 `${}` 插值内——改用 `let val = ...; in "${val}"`       |
| INV-NIX-2  | `rec{}` 自引用函数用 `builtins.concatLists(builtins.map f xs)`  |
| INV-NIX-3  | `rec{}` 内函数传给 `map` 时用 lambda 包装器 `(x: f x)`          |
| INV-NIX-4  | letrec 上下文中不用 `foldl'+` 拼接列表——改用 `concatLists+map`  |
| INV-NIX-5  | `patternVars` 用迭代 BFS（\_extractOne × 8 层），不用递归自引用 |
| INV-SER-1  | `builtins.toJSON` 从不碰 Type / Constraint / 函数值             |
| INV-LET-1  | `let` 绑定不 shadow 外层函数参数（避免 Nix let 互递归死循环）   |
| INV-SUB2   | 替换必须同步（非顺序），避免 capture                            |
| INV-I1-key | `_instanceKey` 用纯字符串拼接，不用 `builtins.toJSON`           |

---

## 扩展指南

新增 TypeRepr 变体只需修改三处：

```nix
# 1. repr/all.nix
rMyVariant = arg: mkRepr "MyVariant" { arg = arg; };

# 2. meta/serialize.nix — 在 _serializeWithEnv 的 if-else 链中添加
else if r.__variant == "MyVariant" then
  "MyVariant(${_ser env depth r.arg})"

# 3. normalize/rules.nix — 如需归约规则则添加
ruleMyVariant = t: ...
```

---

## 版本历史

| 版本  | 核心变更                                                                      |
| ----- | ----------------------------------------------------------------------------- |
| 4.5.9 | INV-NIX-4: patternVars Ctor/Record 改 concatLists+map，eta-expand rec 导出    |
| 4.5.8 | 同上（4.5.9 为修订版本号更新）                                                |
| 4.5.3 | INV-NIX-3 lambda wrapper; 测试框架 mkTestWith/diagnoseAll; nix run .#diagnose |
| 4.5.2 | INV-NIX-2 builtins.concatLists; INV-TOPO; INV-EFF-11 完整实现                 |
| 4.5.1 | INV-BIDIR-3 App result solved; INV-KIND-3 fixpoint; INV-PAT-3 nested Record   |
| 4.5.0 | Phase 4.5 基线                                                                |
| 4.4.0 | INV-BIDIR-2 注解 λ; INV-EFF-11 cont domain; INV-KIND-2; INV-PAT-1/2           |
| 4.3.0 | Kind inference; Mu bisim up-to congruence; Handler cont; INV-SER-1            |
| 4.2.0 | TypeScheme/HM; ComposedFunctor; 全局一致性                                    |
| 4.1.0 | UnifiedSubst; RISK-A~F 全修复; de Bruijn serialize                            |
| 4.0.0 | Constraint IR 化; rowVar solver 注入                                          |

---

## Phase 5.0 规划

```
INV-GRAD-1: Dynamic 与所有类型一致（consistency relation）
INV-GRAD-2: Dynamic 边界显式 cast 插入
INV-HM-1:   infer 产出主类型（principal type）
INV-HM-2:   generalize 严格尊重 Ctx 自由变量
```

- **Gradual Types**：`rDynamic`（已在 repr）+ consistency + cast 插入
- **Full HM Inference**：constraint solving loop 集成进 type inference
- **Decision Tree 共享**：大型 ADT 前缀共享（Maranget 2008）
- **SMT bridge**：真实 SMTLIB2 后端（当前为 oracle stub）
