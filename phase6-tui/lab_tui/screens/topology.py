"""Load a lab.toml, render the dispatch plan, run bring-up / tear-down.

The plan is rendered as a list; execution uses the same subprocess
streaming pattern as the logs screen.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Header, Input, Label, Log, Static

from lab_tui.topology import PhasePlan, plan_down, plan_up


class TopologyScreen(Screen):
    BINDINGS = [
        Binding("escape,q", "app.pop_screen", "Back"),
        Binding("u", "bring_up", "Bring up"),
        Binding("d", "tear_down", "Tear down"),
    ]

    CSS = """
    TopologyScreen { layout: vertical; }
    #top { layout: horizontal; height: auto; padding: 1 1; }
    #top > Input { width: 3fr; }
    #top > Button { margin-left: 1; }
    #plan { height: 8; border: solid $primary-background; padding: 0 1; }
    #output { height: 1fr; border: solid $primary-background; }
    """

    def __init__(self, initial_toml: Path | None = None) -> None:
        super().__init__()
        self._initial_toml = initial_toml

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Horizontal(id="top"):
            yield Input(
                placeholder="path to lab.toml",
                id="toml-path",
                value=str(self._initial_toml) if self._initial_toml else "",
            )
            yield Button("Plan", id="plan-btn", variant="primary")
        yield Static("(enter a lab.toml path and press Plan)", id="plan")
        yield Log(id="output", highlight=True)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = "topology"
        if self._initial_toml:
            self._render_plan()

    def _toml_path(self) -> Path | None:
        raw = self.query_one("#toml-path", Input).value.strip()
        if not raw:
            return None
        p = Path(raw).expanduser()
        return p if p.is_file() else None

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "plan-btn":
            self._render_plan()

    def _render_plan(self) -> None:
        path = self._toml_path()
        plan_pane = self.query_one("#plan", Static)
        if path is None:
            plan_pane.update("[red]file not found[/red]")
            return
        try:
            up_plans = plan_up(path)
            down_plans = plan_down(path)
        except ValueError as e:
            plan_pane.update(f"[red]{e}[/red]")
            return
        lines = ["Up order:"]
        lines += [f"  → {p.description}" for p in up_plans]
        lines.append("Down order:")
        lines += [f"  → {p.description}" for p in down_plans]
        plan_pane.update("\n".join(lines))

    def action_bring_up(self) -> None:
        self._execute("up")

    def action_tear_down(self) -> None:
        path = self._toml_path()
        if path is None:
            return
        plans = plan_down(path)
        from lab_tui.screens.confirm import ConfirmScreen
        self.app.push_screen(
            ConfirmScreen(
                title=f"Tear down {path.name}?",
                # Show the first real command (docker/podman/lxd down)
                # — the full sequence is visible in the plan pane above.
                argv=next(
                    (p.argv for p in plans if p.argv[0] != "echo"),
                    ["echo", "nothing to tear down"],
                ),
            ),
            callback=lambda ok: self._execute("down") if ok else None,
        )

    def _execute(self, op: str) -> None:
        path = self._toml_path()
        if path is None:
            return
        plans = plan_up(path) if op == "up" else plan_down(path)
        self.run_worker(self._run_sequence(plans), exclusive=True)

    async def _run_sequence(self, plans: list[PhasePlan]) -> None:
        log: Log = self.query_one("#output", Log)
        for plan in plans:
            log.write_line("")
            log.write_line(f"=== {plan.description} ===")
            log.write_line(f"$ {' '.join(plan.argv)}")
            try:
                proc = await asyncio.create_subprocess_exec(
                    *plan.argv,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.STDOUT,
                )
            except FileNotFoundError as e:
                log.write_line(f"[error] {e}")
                continue
            assert proc.stdout is not None
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                log.write_line(line.decode(errors="replace").rstrip("\n"))
            rc = await proc.wait()
            log.write_line(f"[phase {plan.slot}: exit {rc}]")
            if rc != 0:
                log.write_line("[halt] stopping on first failure")
                break
