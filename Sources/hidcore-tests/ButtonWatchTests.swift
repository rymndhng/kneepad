import Foundation
import HIDCore
import TouchEvents

// The bookkeeping behind stamping a drag with the press that opened it. The
// tap itself needs a live session and cannot run here; what is pinned is the
// part that decides which number a drag carries, because getting it wrong
// costs nothing visible — the drag is still posted, it is just ignored.

func runButtonWatchTests() {
    TestRunner.suite("Button watch") {

        TestRunner.test("a press we never saw stamps zero") {
            let watch = ButtonWatch()
            // The value the field had before any of this, so a tap that failed
            // to start leaves the driver no worse than it used to be.
            expectEqual(watch.number(for: .left), 0)
        }

        TestRunner.test("a drag carries the number of its own button's press") {
            let watch = ButtonWatch()
            watch.record(button: 0, number: 210)
            watch.record(button: 1, number: 211)

            expectEqual(watch.number(for: .left), 210)
            expectEqual(watch.number(for: .right), 211)
            expectEqual(watch.number(for: .middle), 0, "middle was never pressed")
        }

        TestRunner.test("the newest press wins") {
            let watch = ButtonWatch()
            watch.record(button: 0, number: 210)
            watch.record(button: 0, number: 216)
            expectEqual(watch.number(for: .left), 216)
        }

        // Not forgetting on release is the point: a release clears the entry
        // just as a drag still in flight asks for it, and a drag stamped 0 is
        // dropped by every AppKit tracking loop. The last press of a held
        // button is that button's press, so the record can simply stand.
        TestRunner.test("a press outlives its release") {
            let watch = ButtonWatch()
            watch.record(button: 0, number: 210)
            // Whatever else goes by — including the up, which the tap does not
            // even ask for — the number stays available.
            watch.record(button: 1, number: 211)
            expectEqual(watch.number(for: .left), 210)
        }

        // `anyButtonDown` only ever attributes a drag to left, right or middle,
        // so a mouse's back button has no drag to stamp — and must not land on
        // the middle button's record on its way past.
        TestRunner.test("buttons past the middle one are ignored") {
            let watch = ButtonWatch()
            watch.record(button: 2, number: 300)
            watch.record(button: 3, number: 301)
            watch.record(button: 4, number: 302)
            expectEqual(watch.number(for: .middle), 300)
        }
    }
}
