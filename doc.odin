// Package main is the nabla executable. It owns what belongs to a process: its lifetime
// and signals, the configuration files and their watcher, the catalog refresh thread, the
// terminal interface, the headless server, the ACP interface, and the export command.
//
// Its App record joins the agent's session to the front end that shows it. The app_*.odin
// files divide that record by concern: the transcript, input, menu, catalog, session
// switching, and worker. The package imports the foundation packages and `agent`, and
// nothing imports it. Policy such as tool permissions, model selection rules, or the
// journal format lives in `agent` and is not repeated here.
package main
