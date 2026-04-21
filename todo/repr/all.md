这个文件整体结构是一致的 Phase 3 TypeRepr 扩展，但这里面有几处**语义/实现级问题**，其中一部分属于会直接导致 normalize / equality / freeVars 不正确的级别。

我按严重性分层指出。

---

# 1. ❗ freeVarsRepr 存在“类型混淆 + 错误调用链”

## 问题 A：fvType 实现是错的

```nix
fvType = t: if t ? repr then freeVarsRepr t.repr else {};
```

### 问题点

1. `TypeRepr` 本身已经是 repr，不存在 `t.repr`
2. 这里假设“外层 Type 包装”，但整个系统其他部分都是 **裸 repr**
3. 结果：
   - Pi/Sigma/Apply 等递归在多数情况下**直接失效**
   - freeVars 会“偶发正确，偶发空集”

### 影响

- constraint solver 不稳定（INV-SOL 类问题）
- substitution capture check 失效
- equality coherence 被破坏（INV-3 间接崩）

---

## 正确形式应该是：

```nix
fvType = t: freeVarsRepr t;
```

---

# 2. ❗ Pi / Sigma freeVars 逻辑是错误的（关键）

你现在写的是：

```nix
union [ (fvType repr.paramType)
        (builtins.removeAttrs (fvType repr.body) [ repr.param ]) ]
```

## 问题 A：removeAttrs 用错结构

`fvType repr.body` 是：

```nix
{ x = true; y = true; }
```

但：

```nix
builtins.removeAttrs (fvType repr.body) [ repr.param ]
```

✔ 只有在 param 是 key 才成立
❌ 但 freeVars 是 set，不是 scope environment

---

## 问题 B（更严重）：变量绑定语义是“名字级”，但系统混了 DB / scoped

你系统同时有：

- Var
- VarScoped
- VarDB

但 freeVars：

```nix
Pi(x:A).B(x)
```

只做：

- string remove

没有：

- DB shift handling
- scope-aware binding resolution

---

## 结果

在以下情况会错：

- Lambda capture-safe substitution
- Pi nested binder
- Sigma projection type inference

---

## 正确方向（语义层）

应该区分：

- name-based FV（Var / VarScoped）
- DB index（VarDB -> always freeVars = ∅）
- binder-aware removal via structured environment, not attr removal

---

# 3. ❗ Constructor freeVars 是错误设计

```nix
union ([ (fvType repr.body) ]
       ++ map (p: builtins.removeAttrs (fvType repr.body) [p.name])
              (repr.params or []))
```

## 问题

### 1. repr.body 被重复计算

### 2. removeAttrs 同样错误

params binder 不应该从 body FV 中 remove

因为：

- params 是 constructor parameters
- 不是 body scope binders

### 3. 语义混淆

Constructor ≠ Lambda ≠ Pi

但这里强行当 binder system 处理

---

# 4. ❗ Record / VariantRow rowVar 处理不一致

```nix
fieldFVs // { ${repr.rowVar} = true; }
```

## 问题

rowVar 被当作“自由变量”

但 rowVar 在系统中语义是：

- row polymorphism variable
- 不是 term variable
- 不应该混入 same FV namespace

---

## 影响

会导致：

- row unification污染 term unification
- solver conflation (INV-SOL domain mix)

---

# 5. ❗ buildRowSpine 有类型错误 + semantic bug

```nix
tail   = if tailVar != null
         then { repr = rVar tailVar "row"; }
         else { repr = rRowEmpty; };
```

## 问题 A：类型不一致

你在 system 里：

- repr 是 raw TypeRepr

但这里返回：

```nix
{ repr = ... }
```

=> 直接破坏所有 pattern match

---

## 问题 B：fields 被误用

```nix
fields.${label}
```

但 fold 参数传的是：

```nix
AttrSet String Type
```

没问题，但你在 lambda 中又：

```nix
{ repr = rRowExtend label fields.${label} rowType; }
```

→ rowType 是 wrapper，不是 repr

---

# 6. ⚠️ Effect / Opaque / Ascribe freeVars OK，但 incomplete

### OK：

- Effect → row
- Opaque → none
- Ascribe → t + annotation

### 缺陷：

- 没处理 effect tag 是否 FV
- Ascribe 没考虑 annotation binder scope（如果 annotation 是 Pi）

---

# 7. ⚠️ rConstructor kind 修复注释存在，但未在此文件体现

你标注：

> INV-K1 修复（保留真实 kind）

但：

- freeVarsRepr 不依赖 kind
- 但 constructor params kind propagation 在 solver 层必须一致

当前 file 只是“结构正确”，不是“语义一致”

---

# 结论（核心问题归类）

这个文件最大问题不是“缺功能”，而是：

## ❗ 1. freeVarsRepr 语义不统一（最严重）

- Type / repr 混用
- binder removal 错误
- rowVar 污染 term space

## ❗ 2. binder system 没有统一模型

现在混合三套系统：

- name-based binding
- de Bruijn (VarDB)
- row variables (polymorphic scope)

但 freeVars 是“拼接式实现”，不是统一语义

## ❗ 3. Constructor / Row / Pi 的 binding 语义不一致

---

# 如果你下一步要修（建议优先级）

1. **统一 FV model**
   - define:
     - termFV
     - rowFV
     - effectFV

2. **去掉 removeAttrs binding hack**
   - 改为 explicit binder traversal

3. **RowVar 不进入 term FV namespace**

4. **修 buildRowSpine 返回结构一致性**

---

如果你下一步要做 Phase 3 稳定化，把这一块重写成：

> ✔ uniform binder algebra + 3-sorted FV system（Term/Row/Effect）

这样 solver 会直接稳定一档。
