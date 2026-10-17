# Template notes

The front page (`README.md`) says what this is, what it needs and how to start
a core from it. This file exists only to say two things it does not:

**Fixes go back upstream.** `platform/`, `target/pocket/sdram_ctrl.sv`,
`sram_port.sv`, `platform/pocket/interface/interact.sv` and the framework half
of `core_top.sv` are the same in every core built from this. A bug fixed in one
of them inside a core is a bug still waiting in the next one unless it is fixed
here too — which is how a ROM-download corruption and a menu-reset bug each
reached two cores before anyone noticed they were the same bug.

**`tools/init_core.py` deletes this file**, along with swapping `README.md` for
the core's own. Template notes have no business travelling into a core.
