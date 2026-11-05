import 'dart:async';

import 'package:flutter/foundation.dart';

import '../media_pipeline.dart';
import '../models/chat_message.dart';
import '../models/forward_marker.dart';
import '../models/message_kind.dart';
import '../models/pending_upload.dart';
import 'notifier_service_host.dart';

/// Background media upload queue: a per-conversation LIFO stack drained by ONE
/// worker at a time (most recently picked item runs first). Each task encrypts +
/// uploads the bytes via [MediaPipeline], fills the descriptor on the optimistic
/// outbox bubble, then runs the standard submit path (the host's submitOutbox).
/// A failure flags the bubble `failed` for retry. The optimistic insert + the
/// submit chokepoint stay in the notifier — this owns only the queue + the
/// upload→attach→submit chain. Extracted from `ConversationsNotifier`.
class UploadWorker {
  UploadWorker({
    required NotifierServiceHost host,
    required MediaPipeline media,
    required Future<void> Function({
      required String conversationId,
      required String outboxId,
      required String Function() buildWireBody,
      required List<int>? mediaBytesForCache,
    }) submitOutbox,
    required Future<void> Function(String conversationId, String outboxId)
        markOutboxFailed,
  })  : _host = host,
        _media = media,
        _submitOutbox = submitOutbox,
        _markOutboxFailed = markOutboxFailed;

  final NotifierServiceHost _host;
  final MediaPipeline _media;
  final Future<void> Function({
    required String conversationId,
    required String outboxId,
    required String Function() buildWireBody,
    required List<int>? mediaBytesForCache,
  }) _submitOutbox;
  final Future<void> Function(String, String) _markOutboxFailed;

  final Map<String, List<PendingUpload>> _uploadStack = {};
  final Map<String, Future<void>> _uploadWorkers = {};

  /// Pushes [upload] onto the conversation's LIFO stack and ensures a worker is
  /// running. The worker drains the stack top-down (most recent first).
  void enqueue(PendingUpload upload) {
    final stack = _uploadStack.putIfAbsent(
      upload.conversationId,
      () => <PendingUpload>[],
    );
    stack.add(upload);
    if (!_uploadWorkers.containsKey(upload.conversationId)) {
      final worker = _runUploadWorker(upload.conversationId);
      _uploadWorkers[upload.conversationId] = worker;
      worker.whenComplete(
        () => _uploadWorkers.remove(upload.conversationId),
      );
    }
  }

  /// Drops all queued (not-yet-started) uploads. In-flight workers cull
  /// themselves via `whenComplete`. Used on disconnect / sign-out.
  void clearPending() => _uploadStack.clear();

  /// Completes when the worker for [conversationId] has drained. Test hook for
  /// media-send tests (the send returns once the optimistic bubble is inserted).
  Future<void> waitFor(String conversationId) async {
    while (true) {
      final worker = _uploadWorkers[conversationId];
      if (worker == null) return;
      await worker;
    }
  }

  /// Drains the conversation's LIFO upload stack one task at a time. A failure
  /// on one task doesn't stop the worker — the next task is still drained.
  Future<void> _runUploadWorker(String conversationId) async {
    while (true) {
      final stack = _uploadStack[conversationId];
      if (stack == null || stack.isEmpty) {
        _uploadStack.remove(conversationId);
        return;
      }
      final upload = stack.removeLast();
      await _processUpload(upload);
    }
  }

  /// Runs one queued upload: encrypts + uploads the bytes, fills the descriptor
  /// on the outbox message, then runs the standard submit path. On any failure
  /// the outbox row is flipped to `failed=true, uploading=false`.
  Future<void> _processUpload(PendingUpload upload) async {
    try {
      // Scope the object's download audience to this conversation's participants
      // (the server folds in the uploader for self-sync). Empty — e.g. the convo
      // isn't loaded — falls back to legacy open access, never blocking the send.
      final audience =
          _host.conversation(upload.conversationId)?.mediaAudienceAccountIds;
      final descriptor = await _media.upload(
        kind: upload.kind,
        plaintext: upload.bytes,
        mimeType: upload.mimeType,
        filename: upload.filename,
        waveform: upload.waveform,
        durationMs: upload.durationMs,
        authorizedAccountIds: audience,
      );
      await _attachDescriptorToOutbox(upload, descriptor);
      await _submitOutbox(
        conversationId: upload.conversationId,
        outboxId: upload.outboxId,
        buildWireBody: () {
          // Image, video and file all carry an optional caption after the
          // descriptor line (the receiver splits it off for any media kind).
          final body = upload.kind != MessageKind.voice
              ? (upload.bodyForUI.isEmpty
                  ? descriptor.toJson()
                  : '${descriptor.toJson()}\n${upload.bodyForUI}')
              : descriptor.toJson();
          // Forwarded media carries the same marker header as forwarded text —
          // split off before the descriptor parse on receive.
          return upload.forwarded ? '${ForwardMarker.prefix}$body' : body;
        },
        mediaBytesForCache: upload.bytes,
      );
    } catch (e) {
      // Background task — no caller to throw to; the bubble surfaces failure via
      // the `failed` flag + retry affordance. Log the cause so upload failures
      // are diagnosable rather than silent.
      debugPrint('upload failed for outbox ${upload.outboxId}: $e');
      await _markOutboxFailed(upload.conversationId, upload.outboxId);
    }
  }

  /// Updates the optimistic outbox message with the just-uploaded descriptor +
  /// flips `uploading` to false. Persisted before the submit so an app crash
  /// between upload and submit recovers to "ready to retry" rather than a stuck
  /// spinner.
  Future<void> _attachDescriptorToOutbox(
    PendingUpload upload,
    MediaDescriptor descriptor,
  ) async {
    final live = _host.conversation(upload.conversationId);
    if (live == null) return;
    final replaced = <ChatMessage>[
      for (final m in live.messages)
        m.outboxId == upload.outboxId
            ? m.copyWith(
                mediaId: descriptor.mediaId,
                mediaKey: descriptor.key,
                mediaSha256: descriptor.sha256,
                mediaSize: descriptor.sizeBytes,
                mediaMime: descriptor.mimeType,
                mediaFilename: descriptor.filename,
                voiceWaveform: descriptor.waveform,
                mediaDurationMs: descriptor.durationMs,
                uploading: false,
              )
            : m,
    ];
    _host.setConversation(
        upload.conversationId, live.copyWith(messages: replaced));
    final updated = replaced.firstWhere(
      (m) => m.outboxId == upload.outboxId,
      orElse: () => throw StateError(
          'outbox ${upload.outboxId} missing during descriptor attach'),
    );
    await _host.db.upsertMessages(upload.conversationId, [updated]);
    _host.notifyHost();
  }
}
