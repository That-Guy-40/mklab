"""The main resource browser screen.

Layout:
  ┌─────────────┬────────────────────────────┐
  │  Tree       │  Detail (inspect output)   │
  │             │                            │
  │  (by lab →  │                            │
  │   backend)  │                            │
  │             │                            │
  └─────────────┴────────────────────────────┘

Tree groups by `lab` first, then by backend under each lab — matches the
mental model users have of "my demo lab contains 3 things across 2
engines," which is the reason [lab] exists as a cross-phase idiom.
"""

from __future__ import annotations

import subprocess
from collections import defaultdict

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.screen import Screen
from textual.widgets import Footer, Header, Static, Tree
from textual.widgets.tree import TreeNode

from lab_tui.backends import ALL_BACKENDS, BackendRunner, Resource
from lab_tui.widgets.status_pill import status_pill


def _run_console(app: object, argv: list[str]) -> None:
    """Suspend *app* and run *argv* as a blocking subprocess in the cleared terminal.

    Extracted from action_console() so unit tests can call it without a live
    Textual app (screen.app is a read-only DOMNode property).
    """
    # App.suspend() restores the terminal, yields, then reinstates Textual.
    # Blocking subprocess.run() inside is the documented and intended pattern.
    with app.suspend():  # type: ignore[attr-defined]
        subprocess.run(argv)  # noqa: S603 — caller controls argv

_UNLABELLED = "(unlabelled)"


class ResourceBrowserScreen(Screen):
    BINDINGS = [
        Binding("r", "refresh", "Refresh"),
        Binding("t", "open_topology", "Topology"),
        Binding("l", "open_logs", "Logs"),
        Binding("c", "console", "Console"),
        Binding("d", "destroy", "Destroy"),
        Binding("q", "app.quit", "Quit"),
    ]

    CSS = """
    ResourceBrowserScreen { layout: vertical; }
    #body { layout: horizontal; height: 1fr; }
    #tree-pane { width: 45%; border: solid $primary-background; }
    #detail-pane { width: 1fr; border: solid $primary-background; padding: 0 1; }
    #detail { width: 100%; }
    """

    def __init__(self) -> None:
        super().__init__()
        self._runners: dict[str, BackendRunner] = {
            b.name: b() for b in ALL_BACKENDS
        }
        self._resources_by_id: dict[int, Resource] = {}

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Horizontal(id="body"):
            tree: Tree = Tree("lab-create", id="tree-pane")
            tree.show_root = False
            tree.show_guides = True
            yield tree
            yield Static("Select a resource to inspect.",
                         id="detail-pane", expand=True)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = "resource browser"
        self.refresh_tree()
        self.query_one(Tree).focus()

    # --- actions ----------------------------------------------------------

    def action_refresh(self) -> None:
        self.refresh_tree()

    def action_open_topology(self) -> None:
        from lab_tui.screens.topology import TopologyScreen
        self.app.push_screen(TopologyScreen())

    def action_open_logs(self) -> None:
        resource = self._selected_resource()
        if resource is None or not resource.log_command:
            self.notify("no log tail available for this resource",
                        severity="warning")
            return
        from lab_tui.screens.logs import LogsScreen
        self.app.push_screen(LogsScreen(resource))

    def action_console(self) -> None:
        """Suspend the TUI and attach to the selected resource's serial console.

        Uses App.suspend() so Textual hands back the terminal entirely —
        the attached process gets a real TTY in raw mode.  When the user
        detaches (Ctrl-] for lab-vm.sh console / socat), subprocess.run()
        returns, the context-manager exits, and Textual resumes.

        Only available for running Phase-2 VMs that have a serial.sock.
        """
        resource = self._selected_resource()
        if resource is None or not resource.console_command:
            self.notify(
                "No console available — select a running VM.",
                severity="warning",
            )
            return

        # Print a hint to stderr before suspending so the user knows how to
        # return once the terminal is in raw-socat mode.
        import sys
        print(
            "\n[lab-create TUI] Attaching to console.  Press Ctrl-] to detach and return to the TUI.\n",
            file=sys.stderr,
            flush=True,
        )

        # App.suspend() is a synchronous context manager: it restores the
        # terminal, yields, then reinstates Textual when the block exits.
        # Blocking inside the block is intentional and documented.
        _run_console(self.app, resource.console_command)

    def action_destroy(self) -> None:
        resource = self._selected_resource()
        if resource is None:
            return
        runner = self._runners[resource.backend]
        argv = runner.destroy_argv(resource, force=True)
        from lab_tui.screens.confirm import ConfirmScreen
        self.app.push_screen(
            ConfirmScreen(
                title=f"Destroy {resource.display_name}?",
                argv=argv,
            ),
            callback=self._destroy_callback,
        )

    def _destroy_callback(self, confirmed: bool) -> None:
        if confirmed:
            self.refresh_tree()

    # --- tree building ---------------------------------------------------

    def refresh_tree(self) -> None:
        tree = self.query_one(Tree)
        tree.clear()
        self._resources_by_id.clear()

        # Group: lab → backend → resources
        grouped: dict[str, dict[str, list[Resource]]] = defaultdict(
            lambda: defaultdict(list),
        )
        availability: dict[str, bool] = {}
        for backend_name, runner in self._runners.items():
            availability[backend_name] = runner.is_available()
            if not availability[backend_name]:
                continue
            try:
                resources = runner.list_resources()
            except Exception as exc:  # noqa: BLE001 — surface to the UI
                self.notify(f"{backend_name} list failed: {exc}",
                            severity="error")
                continue
            for r in resources:
                grouped[r.lab or _UNLABELLED][r.backend].append(r)

        # Render.
        for lab_name in sorted(grouped.keys()):
            lab_node = tree.root.add(Text(f"🧪 {lab_name}", style="bold"),
                                     expand=True)
            for backend_name in sorted(grouped[lab_name].keys()):
                resources = grouped[lab_name][backend_name]
                backend_node = lab_node.add(
                    Text(f"{backend_name} ({len(resources)})", style="blue"),
                    expand=True,
                )
                for r in sorted(resources, key=lambda x: x.display_name):
                    label = Text.assemble(
                        (f"{r.svc or r.name}  ", ""),
                        status_pill(r.status),
                        (f"  [{r.type}]", "dim"),
                    )
                    leaf = backend_node.add_leaf(label)
                    self._resources_by_id[id(leaf)] = r

        # Append "(unavailable backends)" group so users see what's missing.
        missing = [b for b, ok in availability.items() if not ok]
        if missing:
            n = tree.root.add(
                Text("unavailable backends", style="dim"),
                expand=False,
            )
            for bname in missing:
                n.add_leaf(Text(f"{bname} (no daemon / script missing)",
                                style="dim"))

        tree.refresh()

    # --- selection hooks --------------------------------------------------

    def _selected_resource(self) -> Resource | None:
        tree = self.query_one(Tree)
        node = tree.cursor_node
        if node is None:
            return None
        return self._resources_by_id.get(id(node))

    def on_tree_node_highlighted(self, event: Tree.NodeHighlighted) -> None:
        resource = self._resources_by_id.get(id(event.node))
        detail = self.query_one("#detail-pane", Static)
        if resource is None:
            detail.update("Select a resource to inspect.")
            return
        # Defer the inspect to a worker so the UI stays responsive.
        self.run_worker(
            self._load_inspect(resource),
            group="inspect",
            exclusive=True,
        )

    async def _load_inspect(self, resource: Resource) -> None:
        runner = self._runners[resource.backend]
        # inspect() is blocking (subprocess.run), so run it in a thread.
        import asyncio
        text = await asyncio.to_thread(runner.inspect, resource)
        header = (
            f"{resource.display_name}   [{resource.type}] "
            f"status={resource.status}   backend={resource.backend}\n"
            + "─" * 60
            + "\n"
        )
        detail = self.query_one("#detail-pane", Static)
        detail.update(header + text)
