//
//  Repeater.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 27/06/2022.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

public final class PowerPolicy {
    public static let shared = PowerPolicy()

    private let queue = DispatchQueue(label: "eu.exelban.Stats.PowerPolicy")
    private var _mode: PowerMode

    public var mode: PowerMode {
        get { self.queue.sync { self._mode } }
        set {
            let changed = self.queue.sync { () -> Bool in
                guard self._mode != newValue else { return false }
                self._mode = newValue
                return true
            }
            guard changed else { return }

            Store.shared.set(key: "power_mode", value: newValue.rawValue)
            NotificationCenter.default.post(name: .powerModeChanged, object: self)
        }
    }

    private init() {
        self._mode = PowerMode(
            rawValue: Store.shared.string(key: "power_mode", defaultValue: PowerMode.standard.rawValue)
        ) ?? .standard

        _ = ProcessInfo.processInfo.thermalState
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.systemPowerStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.systemPowerStateChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    internal func intervalMultiplier() -> Int {
        guard self.mode == .adaptive else { return 1 }

        var multiplier = ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 1
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            multiplier = max(multiplier, 2)
        case .critical:
            multiplier = max(multiplier, 4)
        case .nominal, .fair:
            break
        @unknown default:
            break
        }
        return multiplier
    }

    internal func leewayNanoseconds(interval: Int) -> UInt64 {
        guard self.mode != .standard else { return 200_000_000 }
        let intervalNanoseconds = UInt64(max(1, interval)) * 1_000_000_000
        return min(1_000_000_000, max(200_000_000, intervalNanoseconds / 4))
    }

    @objc private func systemPowerStateChanged() {
        guard self.mode == .adaptive else { return }
        NotificationCenter.default.post(name: .powerModeChanged, object: self)
    }
}

private enum RepeaterState {
    case paused
    case running
}

private final class RepeaterScheduler {
    static let shared = RepeaterScheduler()
    
    private struct Job {
        let callback: () -> Void
        let adaptive: Bool
        var interval: Int
        var state: RepeaterState = .paused
        var nextDeadline: UInt64?
        var inFlight: Bool = false
    }

    private let stateQueue = DispatchQueue(
        label: "eu.exelban.Stats.RepeaterScheduler",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let standardWorkQueue = DispatchQueue(
        label: "eu.exelban.Stats.RepeaterScheduler.standard",
        qos: .default,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
    private let efficientWorkQueue = DispatchQueue(
        label: "eu.exelban.Stats.RepeaterScheduler.efficient",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
    private var jobs: [UUID: Job] = [:]
    private var timer: DispatchSourceTimer?
    
    private init() {
        _ = PowerPolicy.shared
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.powerModeChanged),
            name: .powerModeChanged,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        self.stateQueue.sync {
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func register(id: UUID, interval: Int, adaptive: Bool, callback: @escaping () -> Void) {
        self.stateQueue.async {
            self.jobs[id] = Job(callback: callback, adaptive: adaptive, interval: max(1, interval))
        }
    }

    func unregister(id: UUID) {
        self.stateQueue.async {
            self.jobs.removeValue(forKey: id)
            self.scheduleNextTimer()
        }
    }

    func start(id: UUID) {
        self.stateQueue.async {
            guard var job = self.jobs[id], job.state == .paused else { return }
            job.state = .running
            job.nextDeadline = self.deadline(interval: job.interval, adaptive: job.adaptive)
            self.jobs[id] = job
            self.scheduleNextTimer()
        }
    }

    func pause(id: UUID) {
        self.stateQueue.async {
            guard var job = self.jobs[id], job.state == .running else { return }
            job.state = .paused
            job.nextDeadline = nil
            self.jobs[id] = job
            self.scheduleNextTimer()
        }
    }

    func reset(id: UUID, interval: Int, restart: Bool) {
        self.stateQueue.async {
            guard var job = self.jobs[id] else { return }
            job.interval = max(1, interval)
            job.state = restart ? .running : .paused
            job.nextDeadline = restart ? self.deadline(interval: job.interval, adaptive: job.adaptive) : nil
            self.jobs[id] = job

            if restart && !job.inFlight {
                self.run(id: id, callback: job.callback)
            }
            self.scheduleNextTimer()
        }
    }
    
    private func deadline(
        interval: Int,
        adaptive: Bool,
        from now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        let multiplier = adaptive ? PowerPolicy.shared.intervalMultiplier() : 1
        return now + UInt64(max(1, interval) * multiplier) * 1_000_000_000
    }

    private func scheduleNextTimer() {
        self.timer?.setEventHandler {}
        self.timer?.cancel()
        self.timer = nil

        let activeJobs = self.jobs.values.filter({ $0.state == .running })
        guard let next = activeJobs.compactMap({ $0.nextDeadline }).min() else { return }

        let interval = activeJobs
            .filter({ $0.nextDeadline == next })
            .map({ $0.interval * ($0.adaptive ? PowerPolicy.shared.intervalMultiplier() : 1) })
            .min() ?? 1
        let leeway = PowerPolicy.shared.leewayNanoseconds(interval: interval)
        let timer = DispatchSource.makeTimerSource(queue: self.stateQueue)
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: next),
            leeway: .nanoseconds(Int(min(leeway, UInt64(Int.max))))
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.fireDueJobs()
            self.scheduleNextTimer()
        }
        self.timer = timer
        timer.resume()
    }

    private func fireDueJobs() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dueIDs = self.jobs.compactMap { id, job -> UUID? in
            guard job.state == .running, let deadline = job.nextDeadline, deadline <= now else { return nil }
            return id
        }

        for id in dueIDs {
            guard var job = self.jobs[id] else { continue }
            job.nextDeadline = self.deadline(interval: job.interval, adaptive: job.adaptive, from: now)
            let callback = job.callback
            let shouldRun = !job.inFlight
            if shouldRun {
                job.inFlight = true
            }
            self.jobs[id] = job

            if shouldRun {
                self.run(id: id, callback: callback)
            }
        }
    }

    private func run(id: UUID, callback: @escaping () -> Void) {
        if var job = self.jobs[id] {
            job.inFlight = true
            self.jobs[id] = job
        }
        let workQueue = PowerPolicy.shared.mode == .standard ?
            self.standardWorkQueue :
            self.efficientWorkQueue
        workQueue.async { [weak self] in
            callback()
            self?.stateQueue.async {
                guard var job = self?.jobs[id] else { return }
                job.inFlight = false
                self?.jobs[id] = job
            }
        }
    }
    
    @objc private func powerModeChanged() {
        self.stateQueue.async {
            let now = DispatchTime.now().uptimeNanoseconds
            for id in Array(self.jobs.keys) {
                guard var job = self.jobs[id], job.state == .running else { continue }
                job.nextDeadline = self.deadline(interval: job.interval, adaptive: job.adaptive, from: now)
                self.jobs[id] = job
            }
            self.scheduleNextTimer()
        }
    }
}

internal final class Repeater {
    private let id = UUID()
    private var state: RepeaterState = .paused

    internal init(seconds: Int, adaptive: Bool = true, callback: @escaping (() -> Void)) {
        RepeaterScheduler.shared.register(
            id: self.id,
            interval: seconds,
            adaptive: adaptive,
            callback: callback
        )
    }

    deinit {
        RepeaterScheduler.shared.unregister(id: self.id)
    }

    internal func start() {
        guard self.state == .paused else { return }
        self.state = .running
        RepeaterScheduler.shared.start(id: self.id)
    }
    
    internal func pause() {
        guard self.state == .running else { return }
        self.state = .paused
        RepeaterScheduler.shared.pause(id: self.id)
    }
    
    internal func reset(seconds: Int, restart: Bool = false) {
        self.state = restart ? .running : .paused
        RepeaterScheduler.shared.reset(id: self.id, interval: seconds, restart: restart)
    }
}
