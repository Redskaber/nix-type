# incremental/memo.nix — Phase 4.2
# Memo 层（epoch-based 失效）
{ lib, hashLib }:

let inherit (hashLib) typeHash; in

rec {

  # ══ Memo 结构 ══════════════════════════════════════════════════════════
  # { normalize: {typeId → NF}; substitute: {key → result}; solve: {key → result} }
  emptyMemo = { normalize = {}; substitute = {}; solve = {}; epoch = 0; };

  # ══ Normalize memo ════════════════════════════════════════════════════
  storeNormalize = memo: typeId: nf:
    memo // { normalize = memo.normalize // { ${typeId} = nf; }; };

  lookupNormalize = memo: typeId:
    memo.normalize.${typeId} or null;

  # ══ Substitute memo ════════════════════════════════════════════════════
  storeSubstitute = memo: key: result:
    memo // { substitute = memo.substitute // { ${key} = result; }; };

  lookupSubstitute = memo: key:
    memo.substitute.${key} or null;

  # ══ Solve memo ════════════════════════════════════════════════════════
  storeSolve = memo: key: result:
    memo // { solve = memo.solve // { ${key} = result; }; };

  lookupSolve = memo: key:
    memo.solve.${key} or null;

  # ══ Epoch bump（失效所有 memo）════════════════════════════════════════
  bumpEpoch = memo:
    { normalize = {}; substitute = {}; solve = {}; epoch = memo.epoch + 1; };

  currentEpoch = memo: memo.epoch or 0;
}
