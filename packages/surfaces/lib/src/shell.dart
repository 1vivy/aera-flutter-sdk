/// What a shell command left behind.
class ExecResult {
  const ExecResult(
    this.code,
    this.stdout,
    this.stderr, {
    this.elapsed,
    this.blocked,
  });

  /// A result for a shell the host does not have.
  const ExecResult.unavailable([String why = 'No shell on this host'])
    : code = 127,
      stdout = '',
      stderr = why,
      elapsed = null,
      blocked = null;

  final int code;
  final String stdout;
  final String stderr;

  /// How long the command took, as the app saw it.
  final Duration? elapsed;

  /// How long the host froze the page to run it (KernelSU, Next, SukiSU,
  /// APatch and the standalone host run the command inside the JavaScript
  /// call). Zero or null where commands run in the background.
  final Duration? blocked;

  bool get ok => code == 0;

  @override
  String toString() => 'exit $code${stdout.isEmpty ? '' : '\n$stdout'}'
      '${stderr.isEmpty ? '' : '\n$stderr'}';
}

/// Quotes [value] as one POSIX shell word. Every WebUI host pastes `cwd`,
/// `env` and arguments into a shell line unescaped, so quote anything that
/// did not come from you.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Joins [words] into a shell line, quoting each.
String shellLine(Iterable<String> words) => words.map(shellQuote).join(' ');
