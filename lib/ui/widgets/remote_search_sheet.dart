import 'dart:async';

import 'package:flutter/material.dart';
import 'package:server_core/server_core.dart';
import 'package:uuid/uuid.dart';

import '../../data/services/remote_search_sender.dart';
import '../../l10n/app_localizations.dart';
import '../util/error_message.dart';

/// Also works with ordinary session receivers: unverified text implementations
/// get one explicit Send instead of a stream of replacement values.
class RemoteSearchSheet extends StatefulWidget {
  const RemoteSearchSheet({
    super.key,
    required this.sessionApi,
    required this.sessionId,
    required this.deviceName,
    required this.liveUpdates,
    required this.connected,
  });

  final SessionApi sessionApi;
  final String sessionId;
  final String deviceName;
  final bool liveUpdates;
  final ValueNotifier<bool> connected;

  @override
  State<RemoteSearchSheet> createState() => _RemoteSearchSheetState();
}

class _RemoteSearchSheetState extends State<RemoteSearchSheet>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _focus = FocusNode();
  late RemoteSearchSender _sender;
  Timer? _debounce;
  Object? _error;
  bool _sending = false;
  bool _suspended = false;
  String? _lastQueuedText = '';

  RemoteSearchSender _newSender() {
    final api = widget.sessionApi;
    final id = widget.sessionId;
    final live = widget.liveUpdates;
    return RemoteSearchSender(
      inputId: const Uuid().v4(),
      send: (name, arguments) => api.sendGeneralCommand(
        id,
        name,
        arguments: live
            ? arguments
            : {
                if (arguments.containsKey('String'))
                  'String': arguments['String']!,
              },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _sender = _newSender();
    _text.addListener(_changed);
    widget.connected.addListener(_connectionChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      unawaited(_send());
    });
  }

  void _changed() {
    if (!widget.liveUpdates || _suspended || !widget.connected.value) return;
    if (_text.value.composing.isValid && !_text.value.composing.isCollapsed) {
      _debounce?.cancel();
      _lastQueuedText = null;
      return;
    }
    if (_lastQueuedText == _text.text) return;
    _debounce?.cancel();
    _lastQueuedText = _text.text;
    _sender.setText(_text.text);
    if (_error == null) {
      _debounce = Timer(const Duration(milliseconds: 200), () => _send());
    }
  }

  void _connectionChanged() {
    _debounce?.cancel();
    _sender.close();
    _lastQueuedText = null;
    _sending = false;
    _error = null;
    if (widget.connected.value) _sender = _newSender();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_suspended) {
        _sender = _newSender();
        _lastQueuedText = null;
        setState(() {
          _sending = false;
          _error = null;
        });
      }
      _suspended = false;
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _suspended = true;
      _debounce?.cancel();
      _sender.close();
    }
  }

  Future<void> _send({bool finish = false}) async {
    if (!widget.connected.value || _suspended) return;
    _debounce?.cancel();
    if (finish &&
        _text.value.composing.isValid &&
        !_text.value.composing.isCollapsed) {
      return;
    }
    if (finish) _sender.setText(_text.text);
    setState(() {
      _sending = true;
      _error = null;
    });
    final sender = _sender;
    try {
      await sender.flush();
      if (finish &&
          mounted &&
          identical(sender, _sender) &&
          widget.connected.value &&
          !_suspended) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted && identical(sender, _sender)) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && identical(sender, _sender)) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.connected.removeListener(_connectionChanged);
    _debounce?.cancel();
    _sender.close();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final connected = widget.connected.value;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${l10n.search} · ${widget.deviceName}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _text,
                focusNode: _focus,
                enabled: connected,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _send(finish: true),
                decoration: InputDecoration(
                  hintText: l10n.searchEllipsis,
                  suffixIcon: IconButton(
                    tooltip: l10n.clear,
                    onPressed: connected ? _text.clear : null,
                    icon: const Icon(Icons.clear),
                  ),
                ),
              ),
              if (!connected) Text(l10n.remoteNoSessions),
              if (_error != null) ...[
                Text(l10n.remoteCommandFailed(describeError(_error!, l10n))),
                TextButton(
                  onPressed: () => _send(finish: !widget.liveUpdates),
                  child: Text(l10n.retry),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: connected && !_sending
                    ? () => _send(finish: true)
                    : null,
                child: Text(widget.liveUpdates ? l10n.done : l10n.send),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
