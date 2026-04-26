#!/usr/bin/env python3
import argparse
import csv
import os
import sys
from pathlib import Path


SEGMENTS = [
    ("label_to_endpoint", "Service drain", "#4E79A7"),
    ("endpoint_to_checkpoint", "Checkpoint wait", "#F28E2B"),
    ("checkpoint_to_restore_apply", "Image build/import", "#59A14F"),
    ("restore_apply_to_ready", "Restore Pod Ready", "#E15759"),
    ("ready_to_endpoint_ready", "EndpointSlice ready", "#76B7B2"),
    ("endpoint_ready_to_service", "Service connection", "#B07AA1"),
]


def ns_delta_ms(row, start_key, end_key):
    start = row.get(start_key, "")
    end = row.get(end_key, "")
    if not start or not end:
        return 0.0
    return max(0.0, (int(end) - int(start)) / 1_000_000)


def load_rows(path):
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        rows = []

        for row in reader:
            values = {
                "iteration": row["iteration"],
                "label_to_endpoint": ns_delta_ms(row, "label_remove_ns", "endpoint_source_removed_ns"),
                "endpoint_to_checkpoint": ns_delta_ms(row, "endpoint_source_removed_ns", "checkpoint_success_ns"),
                "checkpoint_to_restore_apply": ns_delta_ms(row, "checkpoint_success_ns", "restore_apply_ns"),
                "restore_apply_to_ready": ns_delta_ms(row, "restore_apply_ns", "restore_ready_ns"),
                "ready_to_endpoint_ready": ns_delta_ms(row, "restore_ready_ns", "endpointslice_restore_ready_ns"),
                "endpoint_ready_to_service": ns_delta_ms(row, "endpointslice_restore_ready_ns", "service_success_ns"),
            }
            values["total"] = sum(values[key] for key, _, _ in SEGMENTS)
            rows.append(values)

    return rows


def render_plot(rows, csv_file, output):
    mpl_config_dir = Path(os.environ.get("MPLCONFIGDIR", "/tmp/matplotlib-cache"))
    mpl_config_dir.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(mpl_config_dir))

    try:
        import matplotlib.pyplot as plt
        from matplotlib.ticker import StrMethodFormatter
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "matplotlib is required. Install it with: python3 -m pip install matplotlib"
        ) from exc

    # 論文向け設定
    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 8,
            "axes.labelsize": 8,
            "axes.titlesize": 8,
            "legend.fontsize": 7,
            "xtick.labelsize": 7,
            "ytick.labelsize": 7,
            "figure.dpi": 150,
            "savefig.dpi": 300,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "svg.fonttype": "none",
            "axes.linewidth": 0.8,
        }
    )

    labels = [str(row["iteration"]) for row in rows]

    # 論文の1カラム幅を意識
    fig_height = max(2.2, 0.35 * len(rows) + 0.8)
    fig, ax = plt.subplots(figsize=(3.6, fig_height))

    left = [0.0] * len(rows)

    for key, label, color in SEGMENTS:
        values = [row[key] for row in rows]

        ax.barh(
            labels,
            values,
            left=left,
            label=label,
            color=color,
            edgecolor="black",
            linewidth=0.25,
            height=0.58,
        )

        left = [base + value for base, value in zip(left, values)]

    # 合計時間を右端に表示
    max_total = max(row["total"] for row in rows)
    for i, row in enumerate(rows):
        ax.text(
            row["total"] + max_total * 0.015,
            i,
            f'{row["total"]:.0f}',
            va="center",
            ha="left",
            fontsize=6.5,
            color="black",
        )

    ax.set_xlabel("Time (ms)")
    ax.set_ylabel("Trial")

    ax.xaxis.set_major_formatter(StrMethodFormatter("{x:,.0f}"))

    # x軸方向だけ薄い補助線
    ax.grid(
        axis="x",
        color="0.88",
        linewidth=0.45,
    )
    ax.set_axisbelow(True)

    # y軸の順序
    ax.invert_yaxis()

    # 論文図っぽく上・右を消す
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    ax.spines["left"].set_linewidth(0.8)
    ax.spines["bottom"].set_linewidth(0.8)

    ax.tick_params(
        axis="both",
        direction="out",
        length=2.5,
        width=0.8,
        color="black",
    )

    # 右側に合計値を書く余白
    ax.set_xlim(0, max_total * 1.13)

    # 凡例を下に整理
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.5, -0.18),
        ncol=2,
        frameon=False,
        handlelength=1.4,
        handleheight=0.8,
        columnspacing=1.0,
        labelspacing=0.4,
        borderaxespad=0.0,
    )

    fig.tight_layout(pad=0.3)
    fig.savefig(output, bbox_inches="tight")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(
        description="Render migration measurement CSV with matplotlib."
    )
    parser.add_argument("csv_file", type=Path)
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args()

    output = args.output
    if output is None:
        output = args.csv_file.with_suffix(".pdf")

    rows = load_rows(args.csv_file)

    if not rows:
        print(f"No rows found in {args.csv_file}", file=sys.stderr)
        return 1

    render_plot(rows, args.csv_file, output)
    print(output)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
