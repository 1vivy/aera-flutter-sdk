import 'package:flutter/material.dart';
import 'package:surfaces/surfaces.dart';

import 'tokens.dart';

/// Keeps page content at a readable width and pads it.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: contentMaxWidth),
        child: ListView(
          padding: padding ??
              EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.m,
                  Gap.xl + MediaQuery.paddingOf(context).bottom),
          children: [
            for (final (index, child) in children.indexed) ...[
              if (index > 0) const SizedBox(height: Gap.m),
              child,
            ],
          ],
        ),
      ),
    );
  }
}

/// A titled card.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: text.titleMedium)),
                ?trailing,
              ],
            ),
            const SizedBox(height: Gap.s),
            child,
          ],
        ),
      ),
    );
  }
}

/// Says whether a capability is here, and what happens instead when it is
/// not: the per-feature fallback, made visible.
class CapabilityRow extends StatelessWidget {
  const CapabilityRow({super.key, required this.capability, this.fallback});

  final String capability;

  /// What the app does without it.
  final String? fallback;

  @override
  Widget build(BuildContext context) {
    final has = Surface.instance.info.has(capability);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            has ? Icons.check_circle : Icons.change_circle_outlined,
            size: 20,
            color: has ? scheme.primary : scheme.tertiary,
          ),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: Cap.describe(capability),
                children: [
                  if (!has && fallback != null)
                    TextSpan(
                      text: '  ·  $fallback',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The host in one line: name, tier and engine.
class HostBanner extends StatelessWidget {
  const HostBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final info = Surface.instance.info;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Row(
          children: [
            Icon(_icon(info.kind), color: scheme.onPrimaryContainer, size: 32),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.version.isEmpty ? info.name : '${info.name} ${info.version}',
                    style: text.titleMedium?.copyWith(color: scheme.onPrimaryContainer),
                  ),
                  Text(
                    '${_tierLabel(info)} · ${info.engine}',
                    style: text.bodySmall?.copyWith(color: scheme.onPrimaryContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _icon(HostKind kind) => switch (kind) {
    HostKind.webui => Icons.admin_panel_settings,
    HostKind.browser => Icons.public,
    HostKind.aera => Icons.healing,
    HostKind.desktop => Icons.desktop_windows,
    HostKind.mobile => Icons.smartphone,
    HostKind.headless => Icons.help_outline,
  };

  static String _tierLabel(HostInfo info) {
    return switch (info.tier) {
      'webuix' => 'WebUI X',
      'webui' => 'KernelSU WebUI',
      'browser' => 'Plain browser',
      final tier => tier,
    };
  }
}

/// A short note in the tertiary colour, for "this host does X instead".
class FallbackNote extends StatelessWidget {
  const FallbackNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.s + Gap.xs),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.onTertiaryContainer)),
          ),
        ],
      ),
    );
  }
}
