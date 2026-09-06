from __future__ import annotations

import json

from dataclasses import (
    asdict,
    dataclass,
)

from pathlib import Path
from typing import Any


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

COUNTRY_ROOT = Path(
    "/var/lib/config-location/country"
)

RESULT_ROOT = (
    COUNTRY_ROOT / "results" / "latest"
)

IDENTITY_ROOT = (
    COUNTRY_ROOT / "country-identity"
)

PIPELINE_ROOT = (
    COUNTRY_ROOT / "pipeline" / "latest"
)


UNKNOWN_VALUES = {
    "",
    "unknown",
    "UNKNOWN",
    "Unknown",
    "ناشناس",
    "none",
    "None",
    "null",
    "--",
}


FINAL_STATES = {
    "confirmed",
    "confirmed_stable",
    "confirmed_rotating_ip",
    "stable",
    "accepted",
    "resolved",
    "final",
    "known",
}


NON_FINAL_STATES = {
    "pending_confirmation",
    "ambiguous",
    "unstable_exit",
    "error",
    "unknown",
    "failed",
    "failure",
    "pending",
}


@dataclass
class CountryEvidence:
    source: str
    config_id: str

    country_code: str | None
    country_name: str | None
    flag: str | None

    confidence: float | None

    state: str | None
    evidence_path: str | None

    locked: bool
    accepted: bool
    reason: str


@dataclass
class CountryProjection:
    config_id: str

    state: str

    country_code: str | None
    country_name: str | None
    flag: str | None

    confidence: float | None

    selected_source: str | None
    selected_path: str | None

    conflict: bool

    evidence_count: int
    accepted_evidence_count: int

    evidence: list[dict[str, Any]]


def read_json(
    path: Path,
) -> Any:

    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return None


def clean(
    value: Any,
) -> str | None:

    if value is None:
        return None

    if not isinstance(
        value,
        (
            str,
            int,
            float,
        ),
    ):
        return None

    value=str(value).strip()

    if value in UNKNOWN_VALUES:
        return None

    return value or None


def normalize_code(
    value: Any,
) -> str | None:

    value=clean(value)

    if not value:
        return None

    value=value.upper()

    if (
        len(value)==2
        and value.isalpha()
    ):
        return value

    return None


def normalize_name(
    value: Any,
) -> str | None:

    value=clean(value)

    if not value:
        return None

    if (
        len(value)==2
        and value.isalpha()
    ):
        return None

    return value


def normalize_confidence(
    value: Any,
) -> float | None:

    try:
        value=float(value)

    except Exception:
        return None

    if value > 1:
        value=value / 100.0

    return max(
        0.0,
        min(
            1.0,
            value,
        ),
    )


def state_value(
    obj: dict[str,Any],
) -> str | None:

    for key in (
        "state",
        "country_state",
        "status",
        "verdict",
        "decision",
        "resolution_state",
    ):

        value=clean(
            obj.get(key)
        )

        if value:
            return value.lower()

    return None


def confidence_value(
    obj: dict[str,Any],
) -> float | None:

    for key in (
        "country_confidence",
        "confidence",
        "score",
    ):

        if key in obj:

            value=normalize_confidence(
                obj.get(key)
            )

            if value is not None:
                return value

    return None


def direct_country(
    obj: dict[str,Any],
) -> tuple[
    str | None,
    str | None,
    str | None,
]:

    code=normalize_code(
        obj.get(
            "country_code"
        )
    )

    name=normalize_name(
        obj.get(
            "country_name"
        )
    )


    country=clean(
        obj.get(
            "country"
        )
    )

    if country:

        if (
            not code
            and len(country)==2
            and country.isalpha()
        ):

            code=country.upper()

        elif not name:

            name=normalize_name(
                country
            )


    flag=clean(
        obj.get("flag")
    )


    return (
        code,
        name,
        flag,
    )


def identity_locked(
    obj: dict[str,Any],
) -> bool:

    metadata=(
        obj.get("metadata")
        if isinstance(
            obj.get("metadata"),
            dict,
        )
        else {}
    )


    values=[
        obj.get(
            "country_identity_locked"
        ),

        obj.get("locked"),

        metadata.get(
            "country_identity_locked"
        ),
    ]


    if any(
        value is True
        for value in values
    ):
        return True


    guard=(
        obj.get(
            "country_identity_guard"
        )
        or metadata.get(
            "country_identity_guard"
        )
    )


    if guard is True:
        return True


    if str(
        guard
    ).strip().lower() in {
        "locked",
        "true",
        "1",
    }:
        return True


    return False


def section_evidence(
    *,
    source: str,
    config_id: str,
    obj: dict[str,Any],
    section_name: str,
    accepted: bool,
    state: str | None,
    reason: str,
    locked: bool=False,
) -> CountryEvidence | None:

    code,name,flag=direct_country(
        obj
    )

    if not (
        code
        or name
    ):
        return None


    return CountryEvidence(
        source=source,
        config_id=config_id,

        country_code=code,
        country_name=name,
        flag=flag,

        confidence=confidence_value(
            obj
        ),

        state=state,
        evidence_path=section_name,

        locked=locked,
        accepted=accepted,
        reason=reason,
    )


def identity_evidence(
    config_id: str,
    obj: dict[str,Any],
) -> list[CountryEvidence]:

    locked=identity_locked(
        obj
    )

    state=state_value(
        obj
    )


    row=section_evidence(
        source="identity",
        config_id=config_id,
        obj=obj,
        section_name="$",
        accepted=locked,
        state=state,
        locked=locked,
        reason=(
            "locked_identity"
            if locked
            else "identity_not_locked"
        ),
    )


    return (
        [row]
        if row
        else []
    )


def result_evidence(
    config_id: str,
    obj: dict[str,Any],
) -> list[CountryEvidence]:

    rows=[]

    top_state=state_value(
        obj
    )


    # Canonical final result:
    # top-level result is accepted only
    # when result state itself is final.
    top_accepted=(
        top_state
        in FINAL_STATES
    )


    row=section_evidence(
        source="results",
        config_id=config_id,
        obj=obj,
        section_name="$",
        accepted=top_accepted,
        state=top_state,
        reason=(
            "final_result"
            if top_accepted
            else (
                "non_final_result:"
                + str(top_state)
            )
        ),
    )

    if row:
        rows.append(row)


    # Primary is evidence, but does not
    # override a non-final top-level result.
    primary=obj.get(
        "primary"
    )

    if isinstance(
        primary,
        dict,
    ):

        primary_state=state_value(
            primary
        )

        primary_final=(
            primary_state
            in FINAL_STATES
        )

        accepted=(
            top_accepted
            and primary_final
        )

        row=section_evidence(
            source="results",
            config_id=config_id,
            obj=primary,
            section_name="$.primary",
            accepted=accepted,
            state=primary_state,
            reason=(
                "final_result_primary"
                if accepted
                else "primary_not_canonical_final"
            ),
        )

        if row:
            rows.append(row)


    return rows


def pipeline_evidence(
    config_id: str,
    obj: dict[str,Any],
) -> list[CountryEvidence]:

    rows=[]

    top_state=state_value(
        obj
    )


    # Hard boundary:
    # non-final pipeline state may contain
    # Country evidence, but it remains
    # shadow-only and cannot resolve.
    top_final=(
        top_state
        in FINAL_STATES
    )


    row=section_evidence(
        source="pipeline_latest",
        config_id=config_id,
        obj=obj,
        section_name="$",
        accepted=top_final,
        state=top_state,
        reason=(
            "final_pipeline"
            if top_final
            else (
                "non_final_pipeline:"
                + str(top_state)
            )
        ),
    )

    if row:
        rows.append(row)


    # Fusion is the strongest nested verdict
    # when the parent pipeline state is final.
    fusion=obj.get(
        "fusion"
    )

    if isinstance(
        fusion,
        dict,
    ):

        fusion_state=state_value(
            fusion
        )

        accepted=(
            top_final
            and fusion_state
            in FINAL_STATES
        )

        row=section_evidence(
            source="pipeline_latest",
            config_id=config_id,
            obj=fusion,
            section_name="$.fusion",
            accepted=accepted,
            state=fusion_state,
            reason=(
                "final_pipeline_fusion"
                if accepted
                else "fusion_not_canonical_final"
            ),
        )

        if row:
            rows.append(row)


    # Primary is usable evidence only when
    # both parent and primary are final.
    primary=obj.get(
        "primary"
    )

    if isinstance(
        primary,
        dict,
    ):

        primary_state=state_value(
            primary
        )

        accepted=(
            top_final
            and primary_state
            in FINAL_STATES
        )

        row=section_evidence(
            source="pipeline_latest",
            config_id=config_id,
            obj=primary,
            section_name="$.primary",
            accepted=accepted,
            state=primary_state,
            reason=(
                "final_pipeline_primary"
                if accepted
                else "primary_not_canonical_final"
            ),
        )

        if row:
            rows.append(row)


    return rows


def direct_path(
    root: Path,
    config_id: str,
) -> Path:

    return (
        root
        / f"{config_id}.json"
    )


def load_evidence(
    config_id: str,
) -> list[CountryEvidence]:

    out=[]


    identity_path=direct_path(
        IDENTITY_ROOT,
        config_id,
    )

    if identity_path.is_file():

        obj=read_json(
            identity_path
        )

        if isinstance(obj,dict):

            out.extend(
                identity_evidence(
                    config_id,
                    obj,
                )
            )


    result_path=direct_path(
        RESULT_ROOT,
        config_id,
    )

    if result_path.is_file():

        obj=read_json(
            result_path
        )

        if isinstance(obj,dict):

            out.extend(
                result_evidence(
                    config_id,
                    obj,
                )
            )


    pipeline_path=direct_path(
        PIPELINE_ROOT,
        config_id,
    )

    if pipeline_path.is_file():

        obj=read_json(
            pipeline_path
        )

        if isinstance(obj,dict):

            out.extend(
                pipeline_evidence(
                    config_id,
                    obj,
                )
            )


    return out


def evidence_key(
    row: CountryEvidence,
) -> str | None:

    if row.country_code:

        return (
            "code:"
            + row.country_code.upper()
        )


    if row.country_name:

        return (
            "name:"
            + row.country_name
            .strip()
            .casefold()
        )


    return None


def accepted_source_rows(
    evidence: list[CountryEvidence],
) -> dict[
    str,
    list[CountryEvidence],
]:

    grouped={}

    for row in evidence:

        if not row.accepted:
            continue

        grouped.setdefault(
            row.source,
            []
        ).append(row)

    return grouped


def source_consensus(
    rows: list[CountryEvidence],
) -> CountryEvidence | None:

    if not rows:
        return None


    keys={
        evidence_key(row)
        for row in rows
        if evidence_key(row)
    }


    if len(keys) != 1:
        return None


    # Prefer strongest nested path.
    path_priority={
        "$.fusion":0,
        "$":1,
        "$.primary":2,
    }


    return sorted(
        rows,
        key=lambda row: (
            path_priority.get(
                row.evidence_path
                or "",
                99,
            ),

            -(
                row.confidence
                if row.confidence
                is not None
                else -1
            ),
        ),
    )[0]


def choose_projection(
    config_id: str,
    evidence: list[CountryEvidence],
) -> CountryProjection:

    grouped=accepted_source_rows(
        evidence
    )


    candidates={}


    for source,rows in grouped.items():

        row=source_consensus(
            rows
        )

        if row is not None:

            candidates[
                source
            ]=row


    # Different accepted sources must agree.
    keys={
        evidence_key(row)
        for row in candidates.values()
        if evidence_key(row)
    }


    if len(keys) > 1:

        return CountryProjection(
            config_id=config_id,

            state="conflict",

            country_code=None,
            country_name=None,
            flag=None,

            confidence=None,

            selected_source=None,
            selected_path=None,

            conflict=True,

            evidence_count=len(
                evidence
            ),

            accepted_evidence_count=sum(
                1
                for row in evidence
                if row.accepted
            ),

            evidence=[
                asdict(row)
                for row in evidence
            ],
        )


    authority=(
        "identity",
        "results",
        "pipeline_latest",
    )


    selected=None


    for source in authority:

        if source in candidates:

            selected=candidates[
                source
            ]

            break


    if selected is None:

        return CountryProjection(
            config_id=config_id,

            state="unknown",

            country_code=None,
            country_name=None,
            flag=None,

            confidence=None,

            selected_source=None,
            selected_path=None,

            conflict=False,

            evidence_count=len(
                evidence
            ),

            accepted_evidence_count=0,

            evidence=[
                asdict(row)
                for row in evidence
            ],
        )


    return CountryProjection(
        config_id=config_id,

        state="resolved",

        country_code=
            selected.country_code,

        country_name=
            selected.country_name,

        flag=
            selected.flag,

        confidence=
            selected.confidence,

        selected_source=
            selected.source,

        selected_path=
            selected.evidence_path,

        conflict=False,

        evidence_count=len(
            evidence
        ),

        accepted_evidence_count=sum(
            1
            for row in evidence
            if row.accepted
        ),

        evidence=[
            asdict(row)
            for row in evidence
        ],
    )


def current_config_ids() -> list[str]:

    ids=[]

    for path in CONFIG_ROOT.glob(
        "*.json"
    ):

        obj=read_json(
            path
        )

        if isinstance(obj,dict):

            cid=obj.get(
                "config_id",
                path.stem,
            )

        else:
            cid=path.stem

        ids.append(
            str(cid)
        )


    return sorted(
        set(ids)
    )


def build_projection() -> dict[str,Any]:

    records={}

    counts={
        "resolved":0,
        "unknown":0,
        "conflict":0,
    }

    source_counts={}
    path_counts={}


    for cid in current_config_ids():

        row=choose_projection(
            cid,
            load_evidence(
                cid
            ),
        )

        records[cid]=asdict(
            row
        )


        counts[row.state]=(
            counts.get(
                row.state,
                0,
            )
            + 1
        )


        if row.selected_source:

            source_counts[
                row.selected_source
            ]=(
                source_counts.get(
                    row.selected_source,
                    0,
                )
                + 1
            )


        if row.selected_path:

            key=(
                row.selected_source
                + ":"
                + row.selected_path
            )

            path_counts[
                key
            ]=(
                path_counts.get(
                    key,
                    0,
                )
                + 1
            )


    return {
        "schema":
            2,

        "mode":
            "production",

        "authority": [
            "locked_identity",
            "final_results",
            "final_pipeline",
        ],

        "accepted_final_states":
            sorted(
                FINAL_STATES
            ),

        "non_final_states":
            sorted(
                NON_FINAL_STATES
            ),

        "current_config_count":
            len(records),

        "counts":
            counts,

        "selected_source_counts":
            source_counts,

        "selected_path_counts":
            path_counts,

        "records":
            records,
    }


def store_ids(
    root: Path,
) -> set[str]:

    ids=set()

    if not root.exists():
        return ids


    for path in root.rglob(
        "*.json"
    ):

        obj=read_json(
            path
        )

        if isinstance(obj,dict):

            cid=(
                obj.get(
                    "config_id"
                )
                or obj.get(
                    "id"
                )
                or path.stem
            )

        else:
            cid=path.stem


        if cid:

            ids.add(
                str(cid)
            )


    return ids


def orphan_inventory() -> dict[str,Any]:

    current=set(
        current_config_ids()
    )

    result={}


    for name,root in (
        ("results",RESULT_ROOT),
        ("identity",IDENTITY_ROOT),
        (
            "pipeline_latest",
            PIPELINE_ROOT,
        ),
    ):

        ids=store_ids(
            root
        )

        orphan=(
            ids - current
        )


        result[name]={
            "record_count":
                len(ids),

            "current_overlap":
                len(
                    ids & current
                ),

            "orphan_count":
                len(orphan),

            "delete_allowed":
                False,
        }


    return result
