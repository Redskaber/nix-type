# incremental/memo.nix — Phase 4.1
# Memo 层（epoch-based cache）
# Phase 4.1 修复：与 QueryDB 统一入口（bumpEpoch 同步两层）
{ lib, hashLib }:

let
  inherit (hashLib) typeHash;

in rec {
  # ── Memo 结构 ─────────────────────────────────────────────────────────────
  # { normalize : AttrSet(typeId:epoch -> NF)
  # , substitute: AttrSet(typeId+varId:epoch -> Type)
  # , solve     : AttrSet(constraintKey:epoch -> SolverResult)
  # , epoch     : Int
  # }

  emptyMemo = { normalize = {}; substitute = {}; solve = {}; epoch = 0; };

  # ── epoch-keyed 存储（同一类型在不同 epoch 有不同结果）──────────────────
  _memoKey = memo: baseKey: "${baseKey}:${builtins.toString memo.epoch}";

  # ── normalize 缓存 ────────────────────────────────────────────────────────
  storeNormalize = memo: t: nf:
    let key = _memoKey memo (typeHash t); in
    memo // { normalize = memo.normalize // { ${key} = nf; }; };

  lookupNormalize = memo: t:
    let
      key    = _memoKey memo (typeHash t);
      cached = memo.normalize.${key} or null;
    in
    if cached != null then { found = true; value = cached; }
    else { found = false; };

  # ── substitute 缓存 ───────────────────────────────────────────────────────
  storeSubstitute = memo: varName: replacement: t: result:
    let
      key = _memoKey memo "${varName}:${typeHash replacement}:${typeHash t}";
    in memo // { substitute = memo.substitute // { ${key} = result; }; };

  lookupSubstitute = memo: varName: replacement: t:
    let
      key    = _memoKey memo "${varName}:${typeHash replacement}:${typeHash t}";
      cached = memo.substitute.${key} or null;
    in
    if cached != null then { found = true; value = cached; }
    else { found = false; };

  # ── solve 缓存 ────────────────────────────────────────────────────────────
  storeSolve = memo: constraintKey: result:
    let key = _memoKey memo constraintKey; in
    memo // { solve = memo.solve // { ${key} = result; }; };

  lookupSolve = memo: constraintKey:
    let
      key    = _memoKey memo constraintKey;
      cached = memo.solve.${key} or null;
    in
    if cached != null then { found = true; value = cached; }
    else { found = false; };

  # ── bumpEpoch（全量失效）───────────────────────────────────────────────
  # Phase 4.1：与 QueryDB.bumpEpochDB 同步调用
  bumpEpoch = memo:
    memo // { epoch = memo.epoch + 1; };

  # ── invalidateType（中粒度：失效特定 type 的所有 memo）───────────────────
  # 比 bumpEpoch 更精确，但仍基于前缀匹配
  invalidateType = memo: typeId:
    let
      allNormKeys = builtins.attrNames memo.normalize;
      toRemove = lib.filter (k: lib.hasPrefix typeId k) allNormKeys;
      newNorm  = builtins.removeAttrs memo.normalize toRemove;
    in
    memo // { normalize = newNorm; };

  # ── Memo 元信息 ───────────────────────────────────────────────────────────
  memoSize = memo:
    { normalize  = builtins.length (builtins.attrNames memo.normalize);
      substitute = builtins.length (builtins.attrNames memo.substitute);
      solve      = builtins.length (builtins.attrNames memo.solve);
    };
}
