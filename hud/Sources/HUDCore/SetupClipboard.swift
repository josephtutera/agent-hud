import Foundation

/// What "copy N problems for an agent" puts on the clipboard.
///
/// The point is that pasting it into any agent, in any repo, is enough for that
/// agent to fix the setup correctly. So it carries three things: what is wrong,
/// how check-setup says to fix each one, and the handful of rules in
/// `~/.agents/AGENTS.md` that decide whether a fix is done properly — an agent
/// that edits a harness's own copy of a file, or fixes one account and not the
/// other, has made the problem worse rather than better.
///
/// Pure text assembly, no side effects, so it can be asserted in tests.
public enum SetupClipboard {

    /// The rules that turn "make check-setup green" into "make the change
    /// correctly". Kept short: a wall of context gets skimmed.
    static let rules = [
        "Change the canonical file in ~/.agents, never a harness's own copy.",
        "A change is only done when it is true for every account and harness it belongs to.",
        "Re-run bin/check-setup.sh and show its output before claiming this is fixed.",
        "Commit on a branch and open a PR. Never merge it.",
    ]

    public static func payload(for setup: SetupBlock?, now: Date = Date()) -> String {
        guard let setup, !setup.isClean else {
            return "My ~/.agents setup reports no problems."
        }

        var lines: [String] = []
        let count = setup.problems == 1 ? "1 problem" : "\(setup.problems) problems"
        lines.append("My ~/.agents setup has \(count). Please fix them.")
        lines.append("")
        lines.append("Reported by bin/check-setup.sh, \(stamp(setup.generatedAt ?? now)).")

        var n = 0
        for section in setup.sections where section.isProblem {
            for problem in section.problems {
                n += 1
                lines.append("")
                lines.append("\(n). \(section.title)")
                lines.append("   PROBLEM  \(problem.message)")
                let fix = [problem.fix, problem.fixCommand]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !fix.isEmpty {
                    lines.append("   FIX      \(fix)")
                }
            }
        }

        lines.append("")
        lines.append("Rules from ~/.agents/AGENTS.md that apply here:")
        lines.append(contentsOf: rules.map { "- \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    /// "Sun Aug 2 at 5:12p", matching how the card stamps everything else.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return "\(f.string(from: date)) at \(Fmt.clock(date))"
    }
}
