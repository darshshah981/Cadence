import Testing
@testable import Cadence

struct ComposePersistentMemoryCommandTests {
    @Test
    func onlyExplicitDurablePhraseCreatesAProposalCommand() {
        #expect(ComposePersistentMemoryCommand.parse(
            "Cadence, remember for later that this project uses SwiftUI."
        ) == .remember(fact: "this project uses SwiftUI."))
        #expect(ComposePersistentMemoryCommand.parse(
            "Remember that this project uses SwiftUI."
        ) == nil)
        #expect(ComposePersistentMemoryCommand.parse(
            "Tell Maya to remember for later that this project uses SwiftUI."
        ) == nil)
        #expect(ComposePersistentMemoryCommand.parse(
            "Cadence, remember for later that"
        ) == nil)
        #expect(ComposePersistentMemoryCommand.parse(
            "Cadence, what do you remember for this document?"
        ) == .inspectCurrentDocument)
        #expect(ComposePersistentMemoryCommand.parse(
            "Cadence, forget saved facts for this document."
        ) == .forgetCurrentDocument)
        #expect(ComposePersistentMemoryCommand.parse(
            "Cadence, correct saved memory the release uses UIKit should be the release uses SwiftUI."
        ) == .correct(
            oldFact: "the release uses UIKit", newFact: "the release uses SwiftUI."
        ))
        #expect(ComposePersistentMemoryCommand.parse(
            "Tell Codex to forget saved facts for this document."
        ) == nil)
    }
}
