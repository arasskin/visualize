Visualize opens its URL with macOS `open`, using the user's default browser. It does not detect Chrome, create app windows, or close browser windows on shutdown.

Ctrl-C stops the server and terminal sessions. Ctrl-D stops the graph worker and replaces the server process with a fresh invocation using the original arguments. Terminal supervisors remain running and their sessions are reattached after startup. The new server opens its URL in the default browser again.

Before restart, inherited descriptors other than standard input, output, and error are closed so old HTTP and terminal connections cannot linger. Browser windows remain under the user's control.
