import {startErrorReporting} from './shared/errors.js';
import {startLatency} from './shared/latency.js';
import {startRenderTrace} from './shared/render-trace.js';
import {createWorkspace} from './panes/workspace.js';
import {createGraph} from './graph/graph.js';
import {createFind} from './graph/find.js';
import {createHover, moduleNames} from './graph/hover.js';
import {createCompose} from './ui/compose.js';
import {createHelp} from './ui/help.js';
import {createFileCommand} from './graph/file-command.js';
import {paneShortcuts} from './panes/shortcuts.js';
import {configCompletions} from './config/completion.js';
import {graphUpdates} from './graph/updates.js';
import {watch} from './shared/watch.js';

startErrorReporting(); startLatency(); startRenderTrace();
let search, hover, workspace, compose;
const openFileCommand = createFileCommand((...args) => workspace.openFileTerminal(...args));
const graph = createGraph(document.getElementById('graph'), {
  onRepaint: () => search?.placeArrow(), onNavigate: () => hover?.hideEdge(), onFileClick: openFileCommand,
});
const getPrefixes = () => [...graph.pane.querySelectorAll('svg g.node > title')].map(title => title.textContent);
const docs = window.CONFIG_DOCS || [], colours = window.CONFIG_COLOURS || [];
const help = createHelp({docs, composing: () => compose?.isOpen(), shutCompose: () => compose?.close()});
hover = createHover(graph);
search = createFind(graph, {moduleNames, help: help.root, shutHelp: help.close,
  prefixCandidates: () => configCompletions('fold ', 5, {docs, prefixes: getPrefixes()}).items});
const initial = [];
const savedConfig = !!window.PANE_POSITIONS?.config;
if (savedConfig) initial.push({id: 'config', file: window.CONFIG_FILE, remote: false, rail: 'top', open: !window.START_EMPTY});
if (window.HARNESS_PRESENT) initial.push({id: 'harness', file: window.PANE_DOCUMENTS?.harness, launch: {recover: true}});
for (const id of window.OPEN_TERMINALS || []) initial.push({id, file: window.PANE_DOCUMENTS?.[id], launch: {recover: true}});
workspace = createWorkspace({template: document.getElementById('panel-template'), initial,
  positions: window.PANE_POSITIONS, labels: window.PANE_LABELS, documentOptions: {docs, colours, getPrefixes}});
compose = createCompose({getPrefixes, docs, colours, lines: window.CONFIG_LINES || [], pickedPanel: workspace.pickedPanel,
  selectPane: workspace.selectPane, beforeOpen: help.close});
paneShortcuts(workspace, compose.input);
hover.wireEdges(); graph.hatchFolded(); graph.fitSoon();
window.addEventListener('load', graph.fitSoon);
window.addEventListener('resize', () => { if (!graph.isTouched()) graph.fit(); });
graphUpdates(graph, search, hover, window.GRAPH_GENERATION ?? -1, result => compose.updateLines(result.lines));
watch('/panes/watch', -1, result => { workspace.syncPanes(result.ids, result.labels, result.documents); });

export {graph, search, hover, workspace};
