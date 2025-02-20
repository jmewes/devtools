// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pedantic/pedantic.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

import '../auto_dispose.dart';
import '../config_specific/import_export/import_export.dart';
import '../config_specific/logger/allowed_error.dart';
import '../config_specific/logger/logger.dart';
import '../globals.dart';
import '../http/http_service.dart';
import '../profiler/cpu_profile_controller.dart';
import '../profiler/cpu_profile_service.dart';
import '../profiler/cpu_profile_transformer.dart';
import '../profiler/profile_granularity.dart';
import '../service_manager.dart';
import '../trace_event.dart';
import '../trees.dart';
import '../ui/search.dart';
import '../utils.dart';
import 'performance_model.dart';
import 'performance_screen.dart';
import 'timeline_event_processor.dart';
import 'timeline_streams.dart';

/// This class contains the business logic for [performance_screen.dart].
///
/// The controller manages the timeline data model and communicates with the
/// view to give and receive data updates. It also manages data processing via
/// [TimelineEventProcessor] and [CpuProfileTransformer].
///
/// This class must not have direct dependencies on dart:html. This allows tests
/// of the complicated logic in this class to run on the VM and will help
/// simplify porting this code to work with Hummingbird.
class PerformanceController
    with
        CpuProfilerControllerProviderMixin,
        SearchControllerMixin<TimelineEvent>
    implements DisposableController {
  PerformanceController() {
    processor = TimelineEventProcessor(this);
    _init();
  }

  final _exportController = ExportController();

  final _cpuProfilerService = CpuProfilerService();

  /// The currently selected timeline event.
  ValueListenable<TimelineEvent> get selectedTimelineEvent =>
      _selectedTimelineEventNotifier;
  final _selectedTimelineEventNotifier = ValueNotifier<TimelineEvent>(null);

  /// The currently selected timeline frame.
  ValueListenable<FlutterFrame> get selectedFrame => _selectedFrameNotifier;
  final _selectedFrameNotifier = ValueNotifier<FlutterFrame>(null);

  /// The flutter frames in the current timeline.
  ValueListenable<List<FlutterFrame>> get flutterFrames => _flutterFrames;
  final _flutterFrames = ValueNotifier<List<FlutterFrame>>([]);

  /// Whether an empty timeline recording was just recorded.
  ValueListenable<bool> get emptyTimeline => _emptyTimeline;
  final _emptyTimeline = ValueNotifier<bool>(false);

  /// Whether the timeline is currently being recorded.
  ValueListenable<bool> get refreshing => _refreshing;
  final _refreshing = ValueNotifier<bool>(false);

  /// Whether the recorded timeline data is currently being processed.
  ValueListenable<bool> get processing => _processing;
  final _processing = ValueNotifier<bool>(false);

  // TODO(jacobr): this isn't accurate. Another page of DevTools
  // or a different instance of DevTools could change this value. We need to
  // sync the value with the server like we do for other vm service extensions
  // that we track with the vm service extension manager.
  // See https://github.com/dart-lang/sdk/issues/41823.
  /// Whether http timeline logging is enabled.
  ValueListenable<bool> get httpTimelineLoggingEnabled =>
      _httpTimelineLoggingEnabled;
  final _httpTimelineLoggingEnabled = ValueNotifier<bool>(false);

  ValueListenable<bool> get badgeTabForJankyFrames => _badgeTabForJankyFrames;
  final _badgeTabForJankyFrames = ValueNotifier<bool>(false);

  // TODO(kenz): switch to use VmFlagManager-like pattern once
  // https://github.com/dart-lang/sdk/issues/41822 is fixed.
  /// Recorded timeline stream values.
  final recordedStreams = [
    dartTimelineStream,
    embedderTimelineStream,
    gcTimelineStream,
    apiTimelineStream,
    compilerTimelineStream,
    compilerVerboseTimelineStream,
    debuggerTimelineStream,
    isolateTimelineStream,
    vmTimelineStream,
  ];

  final threadNamesById = <int, String>{};

  /// Active timeline data.
  ///
  /// This is the true source of data for the UI. In the case of an offline
  /// import, this will begin as a copy of [offlinePerformanceData] (the original
  /// data from the imported file). If any modifications are made while the data
  /// is displayed (e.g. change in selected timeline event, selected frame,
  /// etc.), those changes will be tracked here.
  PerformanceData data;

  /// Timeline data loaded via import.
  ///
  /// This is expected to be null when we are not in [offlineMode].
  ///
  /// This will contain the original data from the imported file, regardless of
  /// any selection modifications that occur while the data is displayed. [data]
  /// will start as a copy of offlineTimelineData in this case, and will track
  /// any data modifications that occur while the data is displayed (e.g. change
  /// in selected timeline event, selected frame, etc.).
  PerformanceData offlinePerformanceData;

  TimelineEventProcessor processor;

  /// Trace events in the current timeline.
  ///
  /// This list is cleared and repopulated each time "Refresh" is clicked.
  List<TraceEventWrapper> allTraceEvents = [];

  Future<void> _initialized;
  Future<void> get initialized => _initialized;

  Future<void> _init() {
    return _initialized = _initHelper();
  }

  Future<void> _initHelper() async {
    await serviceManager.onServiceAvailable;

    // Default to true for profile builds only.
    _badgeTabForJankyFrames.value =
        await serviceManager.connectedApp.isProfileBuild;

    unawaited(allowedError(
      _cpuProfilerService.setProfilePeriod(mediumProfilePeriod),
      logError: false,
    ));
    await setTimelineStreams([
      dartTimelineStream,
      embedderTimelineStream,
      gcTimelineStream,
    ]);
    await toggleHttpRequestLogging(true);

    // Initialize displayRefreshRate.
    _displayRefreshRate.value =
        await serviceManager.queryDisplayRefreshRate ?? defaultRefreshRate;
    data?.displayRefreshRate = _displayRefreshRate.value;
  }

  Future<void> selectTimelineEvent(TimelineEvent event) async {
    if (event == null || data.selectedEvent == event) return;

    data.selectedEvent = event;
    _selectedTimelineEventNotifier.value = event;

    cpuProfilerController.reset();

    // Fetch a profile if not in offline mode and if the profiler is enabled.
    if ((!offlineMode || offlinePerformanceData == null) &&
        cpuProfilerController.profilerEnabled) {
      await getCpuProfileForSelectedEvent();
    }
  }

  Future<void> getCpuProfileForSelectedEvent() async {
    final selectedEvent = data.selectedEvent;
    if (!selectedEvent.isUiEvent) return;

    await cpuProfilerController.pullAndProcessProfile(
      startMicros: selectedEvent.time.start.inMicroseconds,
      extentMicros: selectedEvent.time.duration.inMicroseconds,
      processId: '${selectedEvent.traceEvents.first.id}',
    );
    data.cpuProfileData = cpuProfilerController.dataNotifier.value;
  }

  ValueListenable<double> get displayRefreshRate => _displayRefreshRate;
  final _displayRefreshRate = ValueNotifier<double>(defaultRefreshRate);

  Future<void> toggleSelectedFrame(FlutterFrame frame) async {
    if (frame == null || data == null) {
      return;
    }

    // Unselect [frame] if is already selected.
    if (data.selectedFrame == frame) {
      data.selectedFrame = null;
      _selectedFrameNotifier.value = null;
      return;
    }

    data.selectedFrame = frame;
    _selectedFrameNotifier.value = frame;

    await selectTimelineEvent(frame.uiEventFlow);

    if (debugTimeline && frame != null) {
      final buf = StringBuffer();
      buf.writeln('UI timeline event for frame ${frame.id}:');
      frame.uiEventFlow.format(buf, '  ');
      buf.writeln('\nUI trace for frame ${frame.id}');
      frame.uiEventFlow.writeTraceToBuffer(buf);
      buf.writeln('\Raster timeline event frame ${frame.id}:');
      frame.rasterEventFlow.format(buf, '  ');
      buf.writeln('\nRaster trace for frame ${frame.id}');
      frame.rasterEventFlow.writeTraceToBuffer(buf);
      log(buf.toString());
    }
  }

  void addFrame(FlutterFrame frame) {
    data.frames.add(frame);
  }

  Future<void> refreshData() async {
    await clearData(clearVmTimeline: false);
    data = serviceManager.connectedApp.isFlutterAppNow
        ? PerformanceData(
            displayRefreshRate: await serviceManager.queryDisplayRefreshRate)
        : PerformanceData();

    _emptyTimeline.value = false;
    _refreshing.value = true;
    allTraceEvents.clear();
    final timeline = await serviceManager.service.getVMTimeline();
    primeThreadIds(timeline);
    for (final event in timeline.traceEvents) {
      final eventWrapper = TraceEventWrapper(
        TraceEvent(event.json),
        DateTime.now().millisecondsSinceEpoch,
      );
      allTraceEvents.add(eventWrapper);
    }

    _refreshing.value = false;

    if (allTraceEvents.isEmpty) {
      _emptyTimeline.value = true;
      return;
    }

    _processing.value = true;
    await processTraceEvents(allTraceEvents);
    _processing.value = false;

    _flutterFrames.value = data.frames;

    _maybeBadgeTabForJankyFrames();
  }

  void _maybeBadgeTabForJankyFrames() {
    if (_badgeTabForJankyFrames.value) {
      for (final frame in _flutterFrames.value) {
        if (frame.isJanky(_displayRefreshRate.value)) {
          serviceManager.errorBadgeManager
              .incrementBadgeCount(PerformanceScreen.id);
        }
      }
    }
  }

  void primeThreadIds(vm_service.Timeline timeline) {
    threadNamesById.clear();
    final threadNameEvents = timeline.traceEvents
        .map((event) => TraceEvent(event.json))
        .where((TraceEvent event) {
      return event.phase == 'M' && event.name == 'thread_name';
    }).toList();

    // TODO(kenz): Remove this logic once ui/raster distinction changes are
    // available in the engine.
    int uiThreadId;
    int rasterThreadId;
    for (TraceEvent event in threadNameEvents) {
      final name = event.args['name'];

      // Android: "1.ui (12652)"
      // iOS: "io.flutter.1.ui (12652)"
      // MacOS, Linux, Windows, Dream (g3): "io.flutter.ui (225695)"
      if (name.contains('.ui')) {
        uiThreadId = event.threadId;
      }

      // Android: "1.raster (12651)"
      // iOS: "io.flutter.1.raster (12651)"
      // Linux, Windows, Dream (g3): "io.flutter.raster (12651)"
      // MacOS: Does not exist
      // Also look for .gpu here for older versions of Flutter.
      // TODO(kenz): remove check for .gpu name in April 2021.
      if (name.contains('.raster') || name.contains('.gpu')) {
        rasterThreadId = event.threadId;
      }

      // Android: "1.platform (22585)"
      // iOS: "io.flutter.1.platform (22585)"
      // MacOS, Linux, Windows, Dream (g3): "io.flutter.platform (22596)"
      if (name.contains('.platform')) {
        // MacOS and Flutter apps with platform views do not have a .gpu thread.
        // In these cases, the "Raster" events will come on the .platform thread
        // instead.
        rasterThreadId ??= event.threadId;
      }

      threadNamesById[event.threadId] = name;
    }

    if (uiThreadId == null || rasterThreadId == null) {
      log('Could not find UI thread and / or Raster thread from names: '
          '${threadNamesById.values}');
    }

    processor.primeThreadIds(
      uiThreadId: uiThreadId,
      rasterThreadId: rasterThreadId,
    );
  }

  void addTimelineEvent(TimelineEvent event) {
    data.addTimelineEvent(event);
  }

  FutureOr<void> processTraceEvents(List<TraceEventWrapper> traceEvents) async {
    await processor.processTimeline(traceEvents);
    data.initializeEventGroups(threadNamesById);
    if (data.eventGroups.isEmpty) {
      _emptyTimeline.value = true;
    }
  }

  FutureOr<void> processOfflineData(OfflinePerformanceData offlineData) async {
    await clearData();
    final traceEvents = [
      for (var trace in offlineData.traceEvents)
        TraceEventWrapper(
          TraceEvent(trace),
          DateTime.now().microsecondsSinceEpoch,
        )
    ];

    // TODO(kenz): once each trace event has a ui/raster distinction bit added to
    // the trace, we will not need to infer thread ids. This is not robust.
    final uiThreadId = _threadIdForEvents({uiEventName}, traceEvents);
    final rasterThreadId = _threadIdForEvents({rasterEventName}, traceEvents);

    offlinePerformanceData = offlineData.shallowClone();
    data = offlineData.shallowClone();

    // Process offline data.
    processor.primeThreadIds(
      uiThreadId: uiThreadId,
      rasterThreadId: rasterThreadId,
    );
    await processTraceEvents(traceEvents);
    if (data.cpuProfileData != null) {
      await cpuProfilerController.transformer
          .processData(offlinePerformanceData.cpuProfileData);
    }

    // Set offline data.
    setOfflineData();
  }

  int _threadIdForEvents(
    Set<String> targetEventNames,
    List<TraceEventWrapper> traceEvents,
  ) {
    const invalidThreadId = -1;
    return traceEvents
            .firstWhere(
              (trace) => targetEventNames.contains(trace.event.name),
              orElse: () => null,
            )
            ?.event
            ?.threadId ??
        invalidThreadId;
  }

  void setOfflineData() {
    _flutterFrames.value = offlinePerformanceData.frames;
    final frameToSelect = offlinePerformanceData.frames.firstWhere(
      (frame) => frame.id == offlinePerformanceData.selectedFrameId,
      orElse: () => null,
    );
    if (frameToSelect != null) {
      data.selectedFrame = frameToSelect;
      // TODO(kenz): frames bar chart should listen to this stream and
      // programmatially select the frame from the offline snapshot.
      _selectedFrameNotifier.value = frameToSelect;
    }
    if (offlinePerformanceData.selectedEvent != null) {
      for (var timelineEvent in data.timelineEvents) {
        final eventToSelect = timelineEvent.firstChildWithCondition((event) {
          return event.name == offlinePerformanceData.selectedEvent.name &&
              event.time == offlinePerformanceData.selectedEvent.time;
        });
        if (eventToSelect != null) {
          data
            ..selectedEvent = eventToSelect
            ..cpuProfileData = offlinePerformanceData.cpuProfileData;
          _selectedTimelineEventNotifier.value = eventToSelect;
          break;
        }
      }
    }

    if (offlinePerformanceData.cpuProfileData != null) {
      cpuProfilerController
          .loadOfflineData(offlinePerformanceData.cpuProfileData);
    }
  }

  /// Exports the current timeline data to a .json file.
  ///
  /// This method returns the name of the file that was downloaded.
  String exportData() {
    final encodedData =
        _exportController.encode(PerformanceScreen.id, data.json);
    return _exportController.downloadFile(encodedData);
  }

  @override
  List<TimelineEvent> matchesForSearch(String search) {
    if (search?.isEmpty ?? true) return [];
    final matches = <TimelineEvent>[];
    for (final event in data.timelineEvents) {
      breadthFirstTraversal<TimelineEvent>(event, action: (TimelineEvent e) {
        if (e.name.caseInsensitiveContains(search)) {
          matches.add(e);
        }
      });
    }
    return matches;
  }

  Future<void> toggleHttpRequestLogging(bool state) async {
    await HttpService.toggleHttpRequestLogging(state);
    _httpTimelineLoggingEnabled.value = state;
  }

  Future<void> setTimelineStreams(List<RecordedTimelineStream> streams) async {
    for (final stream in streams) {
      assert(recordedStreams.contains(stream));
      stream.toggle(true);
    }
    await serviceManager.service
        .setVMTimelineFlags(streams.map((s) => s.name).toList());
  }

  // TODO(kenz): this is not as robust as we'd like. Revisit once
  // https://github.com/dart-lang/sdk/issues/41822 is addressed.
  Future<void> toggleTimelineStream(RecordedTimelineStream stream) async {
    final newValue = !stream.enabled.value;
    final timelineFlags =
        (await serviceManager.service.getVMTimelineFlags()).recordedStreams;
    if (timelineFlags.contains(stream.name) && !newValue) {
      timelineFlags.remove(stream.name);
    } else if (!timelineFlags.contains(stream.name) && newValue) {
      timelineFlags.add(stream.name);
    }
    await serviceManager.service.setVMTimelineFlags(timelineFlags);
    stream.toggle(newValue);
  }

  /// Clears the timeline data currently stored by the controller.
  ///
  /// [clearVmTimeline] defaults to true, but should be set to false if you want
  /// to clear the data stored by the controller, but do not want to clear the
  /// data currently stored by the VM.
  Future<void> clearData({bool clearVmTimeline = true}) async {
    if (clearVmTimeline && serviceManager.hasConnection) {
      await serviceManager.service.clearVMTimeline();
    }
    allTraceEvents.clear();
    offlinePerformanceData = null;
    cpuProfilerController.reset();
    data?.clear();
    processor?.reset();
    _emptyTimeline.value = true;
    _flutterFrames.value = [];
    _selectedTimelineEventNotifier.value = null;
    _selectedFrameNotifier.value = null;
    _processing.value = false;
    serviceManager.errorBadgeManager.clearErrors(PerformanceScreen.id);
  }

  void recordTrace(Map<String, dynamic> trace) {
    data?.traceEvents?.add(trace);
  }

  void recordTraceForTimelineEvent(TimelineEvent event) {
    recordTrace(event.beginTraceEventJson);
    event.children.forEach(recordTraceForTimelineEvent);
    if (event.endTraceEventJson != null) {
      recordTrace(event.endTraceEventJson);
    }
  }

  @override
  void dispose() {
    cpuProfilerController.dispose();
    _selectedTimelineEventNotifier.dispose();
  }
}
