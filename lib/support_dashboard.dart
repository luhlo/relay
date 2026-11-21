import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'support_service.dart';

class SupportDashboardPage extends StatefulWidget {
  const SupportDashboardPage({super.key, this.service});
  final RelaySupportService? service;
  @override
  State<SupportDashboardPage> createState() => _SupportDashboardPageState();
}

class _SupportDashboardPageState extends State<SupportDashboardPage> {
  late Future<Map<String, dynamic>> _reports;
  @override
  void initState() {
    super.initState();
    _reports = (widget.service ?? RelaySupportService.instance).dashboard();
  }

  void _refresh() => setState(() {
    _reports = (widget.service ?? RelaySupportService.instance).dashboard();
  });

  String _time(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed == null
        ? ''
        : DateFormat.yMMMd().add_jm().format(parsed.toLocal());
  }

  Widget _reportCard(Map<String, dynamic> row, {required bool technical}) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              technical
                  ? '${row['code'] ?? 'Technical report'} · ${row['event_type'] ?? ''}'
                  : switch (row['category']) {
                      'problem' => 'Problem report',
                      'idea' => 'Feature suggestion',
                      _ => 'Question',
                    },
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              '${row['app_version'] ?? ''} · ${row['platform'] ?? ''} · ${_time(row['created_at'])}',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (!technical) ...[
              SelectableText(row['message']?.toString() ?? ''),
              if (row['reply_email'] != null) ...[
                const SizedBox(height: 10),
                SelectableText('Reply to: ${row['reply_email']}'),
              ],
            ] else ...[
              if (row['operation'] != null)
                Text('Operation: ${row['operation']}'),
              if (row['duration_ms'] != null)
                Text('Duration: ${row['duration_ms']} ms'),
              if (row['fingerprint'] != null)
                Text('Group: ${row['fingerprint']}'),
              if (row['frames'] is List &&
                  (row['frames'] as List).isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText((row['frames'] as List).join('\n')),
              ],
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Support dashboard'),
        actions: [
          IconButton(
            onPressed: _refresh,
            tooltip: 'Refresh reports',
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Feedback'),
            Tab(text: 'Technical reports'),
          ],
        ),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _reports,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      snapshot.error is RelaySupportException
                          ? (snapshot.error as RelaySupportException).message
                          : 'Could not load reports. Sign in to the authorized support account and try again.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _refresh,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }
          return TabBarView(
            children: [
              for (final technical in [false, true])
                Builder(
                  builder: (context) {
                    final rows =
                        (snapshot.data![technical ? 'diagnostics' : 'feedback']
                                    as List? ??
                                [])
                            .whereType<Map>()
                            .map((row) => Map<String, dynamic>.from(row))
                            .toList();
                    return ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Text(
                          'Private support view · Latest 100 reports per tab from the past 30 days.',
                        ),
                        if (technical)
                          const Padding(
                            padding: EdgeInsets.only(top: 8, bottom: 12),
                            child: Text(
                              'Optional Flutter error and slow-operation reports. These counts do not measure total users or feature usage. Android system-level crashes and ANRs are not automatically captured.',
                            ),
                          ),
                        const SizedBox(height: 12),
                        if (rows.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              technical
                                  ? 'No technical reports in this period.'
                                  : 'No feedback in this period.',
                            ),
                          ),
                        for (final row in rows)
                          _reportCard(row, technical: technical),
                      ],
                    );
                  },
                ),
            ],
          );
        },
      ),
    ),
  );
}
