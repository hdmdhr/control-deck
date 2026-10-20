import Foundation

@main struct SogouDictationTests {
    @MainActor static func main() async {
        let url = URL(fileURLWithPath: "/test/Sogou.app")
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        func settle(_ service: SogouDictationService, until phase: SogouDictationService.Phase) async {
            for _ in 0..<500 {
                if service.phase == phase { return }
                await Task.yield()
            }
            preconditionFailure("Session did not settle")
        }
        var presentation = SogouDictationService.Presentation.idle
        var launches = 0
        var result: Bool?
        let service = SogouDictationService(resolve: { url }, launch: { _ in
            launches += 1
            presentation = launches == 1 ? .recording : .idle
        }, inspect: { presentation }, pause: { await Task.yield() })
        service.onFinished = { result = $0 }
        check(service.begin(), "Idle assistant can start")
        await settle(service, until: .recording)
        check(!service.begin(), "Repeated keydown cannot toggle an existing session")
        service.stop(); service.stop()
        await settle(service, until: .idle)
        check(launches == 2 && result == true, "One start and one stop command, verified idle")

        presentation = .idle; launches = 0; result = nil
        let early = SogouDictationService(resolve: { url }, launch: { _ in
            launches += 1
            await Task.yield()
            presentation = launches == 1 ? .recording : .idle
        }, inspect: { presentation }, pause: { await Task.yield() })
        early.onFinished = { result = $0 }
        check(early.begin(), "Starting session accepted")
        early.stop()
        await settle(early, until: .idle)
        check(launches == 2 && result == true, "Release during startup waits for recording before stopping")

        presentation = .recording; launches = 0
        let busy = SogouDictationService(resolve: { url }, launch: { _ in launches += 1 }, inspect: { presentation })
        check(!busy.begin() && launches == 0, "Never toggle the user's pre-existing recording")

        presentation = .idle; launches = 0; result = nil
        let failed = SogouDictationService(resolve: { url }, launch: { _ in launches += 1 },
            inspect: { presentation }, pause: { await Task.yield() })
        failed.onFinished = { result = $0 }
        check(failed.begin(), "Start requested")
        failed.stop()
        await settle(failed, until: .idle)
        check(launches == 1 && result == false, "Failed start never produces a second toggle that could start recording")

        presentation = .idle; launches = 0; result = nil
        let ended = SogouDictationService(resolve: { url }, launch: { _ in launches += 1; presentation = .recording },
            inspect: { presentation }, pause: { await Task.yield() })
        ended.onFinished = { result = $0 }
        check(ended.begin(), "Start requested")
        await settle(ended, until: .recording)
        presentation = .idle
        ended.stop()
        check(launches == 1 && result == false, "Externally ended session is never restarted by release")
        enum ReportedFailure: Error { case exited }
        presentation = .idle; launches = 0; result = nil
        let forwarded = SogouDictationService(resolve: { url }, launch: { _ in
            launches += 1
            presentation = launches == 1 ? .recording : .idle
            throw ReportedFailure.exited
        }, inspect: { presentation }, pause: { await Task.yield() })
        forwarded.onFinished = { result = $0 }
        check(forwarded.begin(), "Forwarded request accepted")
        await settle(forwarded, until: .recording)
        forwarded.stop()
        await settle(forwarded, until: .idle)
        check(result == true && launches == 2, "Single-instance forwarding may exit early; actual bubble state is authoritative")
        print("PASS: Sogou hold/release, startup release, duplicate inputs, busy and failed sessions")
    }
}
