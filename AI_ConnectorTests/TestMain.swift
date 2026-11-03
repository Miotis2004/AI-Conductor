import XCTest

// Entry point for running tests from the command line.
// This file is only used when compiling tests with swiftc directly.

XCTMain([
    testCase(ConversationHistoryTests.allTests),
    testCase(ChatExportSerializationTests.allTests),
    testCase(ChatExportFileTests.allTests),
    testCase(PromptClearingTests.allTests),
])
