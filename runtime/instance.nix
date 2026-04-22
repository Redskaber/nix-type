# runtime/instance.nix — Phase 4.2
# Instance DB（RISK-A/B 修复，NF-hash instanceKey）
# INV-I1: instanceKey = canonical hash（α-等价 → 相同 key）
# INV-I2: canDischarge requires impl != null（soundness）
{ lib, typeLib, reprLib, kindLib, hashLib, normalizeLib }:

let
  inherit (typeLib) isType mkTypeDefault;
  inherit (hashLib) typeHash;
  inherit (normalizeLib) normalize';

in rec {

  # ══ Instance 结构 ══════════════════════════════════════════════════════
  # Type: Type → String → Any → Instance
  mkInstance = ty: ctorName: data:
    let
      normType = normalize' ty;
      typeH    = typeHash normType;
      dataH    = builtins.hashString "sha256" (builtins.toJSON data);
    in {
      __type = "Instance";
      type   = normType;
      ctor   = ctorName;
      data   = data;
      hash   = builtins.hashString "sha256" "${typeH}:${dataH}";
    };

  isInstance = i:
    builtins.isAttrs i && (i.__type or null) == "Instance";

  instanceEq = a: b:
    assert isInstance a && isInstance b;
    a.hash == b.hash;

  instanceData = i: assert isInstance i; i.data;
  instanceType = i: assert isInstance i; i.type;

  # ══ Typeclass Instance 注册结构 ════════════════════════════════════════
  # instanceRecord: { className; args: [Type]; impl; superclasses }
  mkInstanceRecord = className: args: impl: superclasses:
    let
      # INV-I1 (RISK-B修复): NF-hash key（不用 toJSON）
      normArgs = map normalize' args;
      argHashes = lib.sort builtins.lessThan (map typeHash normArgs);
      key = builtins.hashString "sha256"
        (builtins.toJSON { c = className; a = argHashes; });
      superclasses = if superclasses != null then superclasses else [];
    in {
      __type       = "InstanceRecord";
      className    = className;
      args         = normArgs;
      impl         = impl;
      superclasses = superclasses;
      key          = key;
    };

  isInstanceRecord = r:
    builtins.isAttrs r && (r.__type or null) == "InstanceRecord";

  # ══ Instance DB ════════════════════════════════════════════════════════
  # DB = { className → { instanceKey → InstanceRecord } }
  emptyDB = {};

  # Type: DB → InstanceRecord → DB
  registerInstance = db: record:
    assert isInstanceRecord record;
    let
      existing = db.${record.className} or {};
    in
    db // { ${record.className} = existing // { ${record.key} = record; }; };

  # Type: DB → String → [Type] → InstanceRecord | null
  lookupInstance = db: className: args:
    let
      normArgs  = map normalize' args;
      argHashes = lib.sort builtins.lessThan (map typeHash normArgs);
      key       = builtins.hashString "sha256"
        (builtins.toJSON { c = className; a = argHashes; });
      classDB   = db.${className} or {};
    in
    classDB.${key} or null;

  # ══ resolveWithFallback（RISK-A 修复）════════════════════════════════
  # INV-I2: found=true requires impl != null
  # Type: ClassGraph → DB → String → [Type] → { found: Bool; impl; }
  resolveWithFallback = classGraph: db: className: args:
    let
      direct = lookupInstance db className args;
    in
    if direct != null then
      # Direct instance found
      { found = true; impl = direct.impl; record = direct; }
    else
      # Try superclass resolution
      let
        superclasses = (classGraph.${className} or {}).superclasses or [];
        superResult = lib.foldl' (acc: superClass:
          if acc.found then acc
          else resolveWithFallback classGraph db superClass args
        ) { found = false; impl = null; record = null; } superclasses;
      in
      if superResult.found && superResult.impl != null then
        # INV-I2: only return found=true if impl != null
        superResult
      else
        { found = false; impl = null; record = null; };

  # INV-I2 guard（RISK-A 修复）
  canDischarge = resolveResult:
    resolveResult.found && resolveResult.impl != null;

  # ══ Phase 4.2: Global Coherence Check ════════════════════════════════
  # INV-COH-1: No two instances overlap（全局一致性）
  # 检测 DB 中是否存在重叠（相同 className + unifiable args）的 instances
  checkGlobalCoherence = db: unifyFn:
    let
      checkClass = className: classDB:
        let
          records = builtins.attrValues classDB;
          pairs   = lib.concatLists (lib.imap0 (i: r1:
            lib.imap0 (j: r2:
              if i >= j then []
              else [ { a = r1; b = r2; } ]
            ) records
          ) records);
          conflicts = lib.filter (pair:
            let
              r = lib.foldl' (acc: p:
                if !acc.ok then acc
                else unifyFn p.fst p.snd
              ) { ok = true; subst = {}; }
                (lib.zipListsWith (x: y: { fst = x; snd = y; })
                  pair.a.args pair.b.args);
            in
            r.ok
          ) pairs;
        in
        map (conflict: {
          className  = className;
          instance1  = conflict.a.key;
          instance2  = conflict.b.key;
        }) conflicts;
    in
    let
      allConflicts = lib.concatLists (lib.mapAttrsToList checkClass db);
    in
    { ok = allConflicts == []; conflicts = allConflicts; };

  # ══ mergeLocalInstances（INV-MOD-7, Phase 4.2 升级）═════════════════
  # Phase 4.2: 支持 partial-unify overlap detection
  # Type: DB(global) → DB(local) → UnifyFn → MergeResult
  mergeLocalInstances = global: local: unifyFn:
    let
      localClasses = builtins.attrNames local;
      # 检查 local 中每个 class 是否与 global 有 overlap
      conflicts = lib.concatLists (map (className:
        let
          localRecords  = builtins.attrValues (local.${className} or {});
          globalRecords = builtins.attrValues (global.${className} or {});
        in
        lib.concatLists (map (lr:
          lib.filter (gr:
            let
              r = lib.foldl' (acc: p:
                if !acc.ok then acc
                else unifyFn p.fst p.snd
              ) { ok = true; subst = {}; }
                (lib.zipListsWith (x: y: { fst = x; snd = y; }) lr.args gr.args);
            in r.ok
          ) globalRecords
        ) localRecords)
      ) localClasses);
    in
    if conflicts != [] then
      { ok = false; conflicts = map (r: r.key) conflicts; db = global; }
    else
      let
        merged = lib.foldl' (acc: className:
          let localClass  = local.${className} or {};
              globalClass = acc.${className} or {};
          in acc // { ${className} = globalClass // localClass; }
        ) global localClasses;
      in
      { ok = true; conflicts = []; db = merged; };
}
