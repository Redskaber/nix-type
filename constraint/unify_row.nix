# constraint/unify_row.nix — Phase 4.1
# Row 合一（开放行多态）
# 支持 RowVar（行变量）的合一
{ lib, typeLib, reprLib, kindLib, substLib, normalizeLib }:

let
  inherit (typeLib) isType mkTypeWith mkTypeDefault;
  inherit (reprLib) rRowExtend rRowEmpty rRowVar isRowEmpty isRowVar isRowExtend;
  inherit (kindLib) KRow;
  inherit (substLib) substitute;
  inherit (normalizeLib) normalize';

  # ── Row spine 展开 ────────────────────────────────────────────────────────
  flattenRow = t:
    let v = t.repr.__variant or null; in
    if v == "RowExtend" then
      let rest = flattenRow t.repr.rest; in
      { entries = [ { label = t.repr.label; fieldType = t.repr.fieldType; } ] ++ rest.entries;
        tail    = rest.tail; }
    else
      { entries = []; tail = t; };

  # ── Row 重建 ──────────────────────────────────────────────────────────────
  rebuildRow = entries: tail:
    lib.foldr
      (e: acc:
        mkTypeDefault (rRowExtend e.label e.fieldType acc) KRow)
      tail
      entries;

  # ── RowVar subst（行变量替换）────────────────────────────────────────────
  applyRowVarSubst = rowSubst: t:
    if !isType t then t
    else
      let v = t.repr.__variant or null; in
      if v == "RowVar" then
        let bound = rowSubst.${t.repr.name} or null; in
        if bound == null then t else bound
      else if v == "RowExtend" then
        let
          ft'   = applyRowVarSubst rowSubst t.repr.fieldType;
          rest' = applyRowVarSubst rowSubst t.repr.rest;
        in mkTypeWith (rRowExtend t.repr.label ft' rest') t.kind t.meta
      else t;

  # ── Row 合一主函数 ────────────────────────────────────────────────────────
  # Type: AttrSet -> Type -> Type -> { ok; typeSubst; rowSubst; error? }
  unifyRow = typeSubst: rowSubst: r1: r2:
    let
      flat1 = flattenRow r1;
      flat2 = flattenRow r2;
      tail1 = flat1.tail;
      tail2 = flat2.tail;
      entries1 = flat1.entries;
      entries2 = flat2.entries;

      # 按 label 分组
      labels1 = map (e: e.label) entries1;
      labels2 = map (e: e.label) entries2;
      allLabels = lib.unique (labels1 ++ labels2);

      # 匹配公共 label
      commonLabels = lib.filter (l: builtins.elem l labels1 && builtins.elem l labels2) allLabels;
      only1        = lib.filter (l: builtins.elem l labels1 && !(builtins.elem l labels2)) allLabels;
      only2        = lib.filter (l: !(builtins.elem l labels1) && builtins.elem l labels2) allLabels;

      getField = entries: label:
        let e = lib.findFirst (x: x.label == label) null entries; in
        if e == null then null else e.fieldType;

      # 合一公共 label 的类型
      matchResult = lib.foldl'
        (acc: label:
          if !acc.ok then acc
          else
            let
              ft1 = getField entries1 label;
              ft2 = getField entries2 label;
            in
            if ft1 == null || ft2 == null
            then { ok = false; typeSubst = acc.typeSubst; rowSubst = acc.rowSubst;
                   error = "Row label ${label} missing"; }
            else
              # 使用类型合一（这里简化：hash 比较）
              if builtins.toJSON ft1.repr == builtins.toJSON ft2.repr
              then acc
              else
                let v1 = ft1.repr.__variant or null; in
                if v1 == "Var" then
                  { ok = true;
                    typeSubst = acc.typeSubst // { ${ft1.repr.name} = ft2; };
                    rowSubst  = acc.rowSubst; }
                else
                  let v2 = ft2.repr.__variant or null; in
                  if v2 == "Var" then
                    { ok = true;
                      typeSubst = acc.typeSubst // { ${ft2.repr.name} = ft1; };
                      rowSubst  = acc.rowSubst; }
                  else
                    { ok = false;
                      typeSubst = acc.typeSubst;
                      rowSubst  = acc.rowSubst;
                      error = "Row field type mismatch at ${label}"; })
        { ok = true; typeSubst = typeSubst; rowSubst = rowSubst; }
        commonLabels;

      # 处理 only1（r1 有但 r2 没有的 label）
      # 如果 r2.tail 是 RowVar，可以扩展
      # 如果 r2.tail 是 RowEmpty，则 r1 多出的 label 报错
      result1 = matchResult;
    in
    if !result1.ok then result1
    else
      let
        vTail1 = tail1.repr.__variant or null;
        vTail2 = tail2.repr.__variant or null;
      in
      # 两个尾都是 RowEmpty，且 only1/only2 都为空 → 完全匹配
      if only1 == [] && only2 == [] && vTail1 == "RowEmpty" && vTail2 == "RowEmpty"
      then { ok = true; typeSubst = result1.typeSubst; rowSubst = result1.rowSubst; }

      # r1 多出 label，r2.tail 是 RowVar → 绑定 r2.tail = {only1} ++ r1.tail
      else if only1 != [] && vTail2 == "RowVar" then
        let
          extra1 = lib.filter (l: builtins.elem l only1) labels1;
          extraEntries = map (l: { label = l; fieldType = getField entries1 l; }) extra1;
          extendedRow  = rebuildRow extraEntries tail1;
          rowVarName   = tail2.repr.name;
        in
        if result1.rowSubst ? ${rowVarName} then
          # 已有绑定，检查一致性（简化：不重合一）
          result1
        else
          { ok = true;
            typeSubst = result1.typeSubst;
            rowSubst  = result1.rowSubst // { ${rowVarName} = extendedRow; }; }

      # r2 多出 label，r1.tail 是 RowVar
      else if only2 != [] && vTail1 == "RowVar" then
        let
          extra2 = lib.filter (l: builtins.elem l only2) labels2;
          extraEntries = map (l: { label = l; fieldType = getField entries2 l; }) extra2;
          extendedRow  = rebuildRow extraEntries tail2;
          rowVarName   = tail1.repr.name;
        in
        if result1.rowSubst ? ${rowVarName} then result1
        else
          { ok = true;
            typeSubst = result1.typeSubst;
            rowSubst  = result1.rowSubst // { ${rowVarName} = extendedRow; }; }

      # 两个 RowVar 互相绑定（引入新 RowVar 作为尾）
      else if vTail1 == "RowVar" && vTail2 == "RowVar" && tail1.repr.name != tail2.repr.name then
        let
          freshRowVar = mkTypeDefault (rRowVar ("_r_" +
            builtins.substring 0 8
              (builtins.hashString "md5" "${tail1.repr.name}${tail2.repr.name}"))) KRow;
          extra1Entries = map (l: { label = l; fieldType = getField entries1 l; }) only1;
          extra2Entries = map (l: { label = l; fieldType = getField entries2 l; }) only2;
          bound1 = rebuildRow extra2Entries freshRowVar;
          bound2 = rebuildRow extra1Entries freshRowVar;
        in
        { ok = true;
          typeSubst = result1.typeSubst;
          rowSubst  = result1.rowSubst
                   // { ${tail1.repr.name} = bound1; }
                   // { ${tail2.repr.name} = bound2; }; }

      # 不匹配的情况
      else if only1 != [] || only2 != []
      then { ok = false; typeSubst = result1.typeSubst; rowSubst = result1.rowSubst;
             error = "Row labels unmatched: only-in-r1=${builtins.toJSON only1} only-in-r2=${builtins.toJSON only2}"; }

      else result1;

in {
  inherit unifyRow flattenRow rebuildRow applyRowVarSubst;
}
