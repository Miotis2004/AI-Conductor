import XCTest
import Foundation

// MARK: - Context Budget Service Tests

final class ContextBudgetServiceTests: XCTestCase {

    static var allTests = [
        ("testEstimateTokensEmpty", testEstimateTokensEmpty),
        ("testEstimateTokensSingleChar", testEstimateTokensSingleChar),
        ("testEstimateTokensFourChars", testEstimateTokensFourChars),
        ("testEstimateTokensEightChars", testEstimateTokensEightChars),
        ("testEstimateTokensLongText", testEstimateTokensLongText),
        ("testEstimateTokensUnicode", testEstimateTokensUnicode),
        ("testBudgetNoMaxModelLen", testBudgetNoMaxModelLen),
        ("testBudgetWithinLimit", testBudgetWithinLimit),
        ("testBudgetExceedsLimit", testBudgetExceedsLimit),
        ("testBudgetExactlyAtLimit", testBudgetExactlyAtLimit),
        ("testBudgetWithAttachments", testBudgetWithAttachments),
        ("testBudgetWithTokenEstimates", testBudgetWithTokenEstimates),
        ("testWarningNoMetadata", testWarningNoMetadata),
        ("testWarningExceedsBudget", testWarningExceedsBudget),
        ("testWarningCloseToLimit", testWarningCloseToLimit),
        ("testWarningWithinBudget", testWarningWithinBudget),
        ("testUsableContextCalculation", testUsableContextCalculation),
        ("testOverageCalculation", testOverageCalculation),
    ]

    private let service = ContextBudgetService()

    func testEstimateTokensEmpty() {
        XCTAssertEqual(service.estimateTokens(for: ""), 0)
    }

    func testEstimateTokensSingleChar() {
        // 1 char / 4 = 0.25, ceil = 1
        XCTAssertEqual(service.estimateTokens(for: "a"), 1)
    }

    func testEstimateTokensFourChars() {
        // 4 chars / 4 = 1
        XCTAssertEqual(service.estimateTokens(for: "abcd"), 1)
    }

    func testEstimateTokensEightChars() {
        // 8 chars / 4 = 2
        XCTAssertEqual(service.estimateTokens(for: "abcdefgh"), 2)
    }

    func testEstimateTokensLongText() {
        // 100 chars / 4 = 25
        let text = String(repeating: "a", count: 100)
        XCTAssertEqual(service.estimateTokens(for: text), 25)
    }

    func testEstimateTokensUnicode() {
        // Unicode characters count as 1 each in Swift's String.count
        let text = "héllo wörld" // 11 characters
        let expected = Int(ceil(11.0 / 4.0)) // 3
        XCTAssertEqual(service.estimateTokens(for: text), expected)
    }

    func testBudgetNoMaxModelLen() {
        let budget = service.calculateBudget(
            maxModelLen: nil,
            promptText: "Hello world",
            attachmentContents: []
        )
        XCTAssertNil(budget.maxModelLen)
        XCTAssertNil(budget.usableContext)
        XCTAssertFalse(budget.exceedsBudget)
        XCTAssertFalse(budget.hasReliableMetadata)
        XCTAssertEqual(budget.overage, 0)
    }

    func testBudgetWithinLimit() {
        let budget = service.calculateBudget(
            maxModelLen: 4096,
            promptText: "Hello",
            attachmentContents: []
        )
        // "Hello" = 5 chars / 4 = 2 tokens (ceil)
        // Total = 2 + 50 (overhead) = 52
        // Usable = 4096 - 1024 = 3072
        // 52 < 3072, so within budget
        XCTAssertEqual(budget.maxModelLen, 4096)
        XCTAssertEqual(budget.usableContext, 3072)
        XCTAssertFalse(budget.exceedsBudget)
        XCTAssertTrue(budget.hasReliableMetadata)
        XCTAssertEqual(budget.overage, 0)
    }

    func testBudgetExceedsLimit() {
        // Use a very small max model len to force exceeding
        let budget = service.calculateBudget(
            maxModelLen: 100,
            promptText: String(repeating: "a", count: 400), // 100 tokens
            attachmentContents: []
        )
        // Total = 100 + 50 = 150
        // Usable = 100 - 1024 = max(0, -924) = 0
        // 150 > 0, so exceeds
        XCTAssertEqual(budget.usableContext, 0)
        XCTAssertTrue(budget.exceedsBudget)
        XCTAssertEqual(budget.overage, 150)
    }

    func testBudgetExactlyAtLimit() {
        // Craft a prompt that exactly fills the budget
        // Usable = 200 - 100 = 100
        // Need total = 100, so prompt tokens = 100 - 50 = 50
        // 50 tokens * 4 chars/token = 200 chars
        let budget = service.calculateBudget(
            maxModelLen: 200,
            promptText: String(repeating: "a", count: 200), // 50 tokens
            attachmentContents: []
        )
        // Total = 50 + 50 = 100
        // Usable = 200 - 100 = 100
        // 100 > 100 is false, so NOT exceeding
        XCTAssertEqual(budget.totalEstimatedTokens, 100)
        XCTAssertEqual(budget.usableContext, 100)
        XCTAssertFalse(budget.exceedsBudget)
    }

    func testBudgetWithAttachments() {
        let budget = service.calculateBudget(
            maxModelLen: 8192,
            promptText: "Explain this code",
            attachmentContents: [
                String(repeating: "x", count: 400), // 100 tokens
                String(repeating: "y", count: 800), // 200 tokens
            ]
        )
        // Prompt: "Explain this code" = 17 chars / 4 = 5 tokens (ceil)
        // Attachments: 100 + 200 = 300 tokens
        // Total prompt = 5 + 300 = 305
        // Total = 305 + 50 = 355
        // Usable = 8192 - 1024 = 7168
        XCTAssertEqual(budget.estimatedPromptTokens, 305)
        XCTAssertEqual(budget.totalEstimatedTokens, 355)
        XCTAssertFalse(budget.exceedsBudget)
    }

    func testBudgetWithTokenEstimates() {
        let budget = service.calculateBudget(
            maxModelLen: 4096,
            promptText: "Hello", // 2 tokens
            attachmentTokenEstimates: [100, 200]
        )
        // Total prompt = 2 + 300 = 302
        // Total = 302 + 50 = 352
        XCTAssertEqual(budget.estimatedPromptTokens, 302)
        XCTAssertEqual(budget.totalEstimatedTokens, 352)
    }

    func testWarningNoMetadata() {
        let budget = service.calculateBudget(
            maxModelLen: nil,
            promptText: "Hello",
            attachmentContents: []
        )
        let warning = service.warningMessage(for: budget)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("unknown"))
    }

    func testWarningExceedsBudget() {
        let budget = service.calculateBudget(
            maxModelLen: 100,
            promptText: String(repeating: "a", count: 400),
            attachmentContents: []
        )
        let warning = service.warningMessage(for: budget)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("exceeds"))
    }

    func testWarningCloseToLimit() {
        // Usable = 1000 - 100 = 900
        // Need > 80% of 900 = 720 tokens total
        // Prompt tokens = 720 - 50 = 670, chars = 670 * 4 = 2680
        let _ = service.calculateBudget(
            maxModelLen: 1000,
            promptText: String(repeating: "a", count: 2680), // 670 tokens
            attachmentContents: []
        )
        // Total = 670 + 50 = 720
        // 720 / 900 = 0.8, not > 0.8, so no warning
        // Let's use slightly more
        let budget2 = service.calculateBudget(
            maxModelLen: 1000,
            promptText: String(repeating: "a", count: 2700), // 675 tokens
            attachmentContents: []
        )
        // Total = 675 + 50 = 725
        // 725 / 900 = 0.8055 > 0.8, warning
        let warning = service.warningMessage(for: budget2)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("%"))
    }

    func testWarningWithinBudget() {
        let budget = service.calculateBudget(
            maxModelLen: 4096,
            promptText: "Hello",
            attachmentContents: []
        )
        // Total = 2 + 50 = 52, usable = 3072
        // 52 / 3072 = 0.017, well under 80%
        let warning = service.warningMessage(for: budget)
        XCTAssertNil(warning)
    }

    func testUsableContextCalculation() {
        let budget = ContextBudget(
            maxModelLen: 8192,
            outputReserve: 2048,
            estimatedPromptTokens: 100,
            overheadTokens: 50
        )
        XCTAssertEqual(budget.usableContext, 6144)
    }

    func testOverageCalculation() {
        let budget = ContextBudget(
            maxModelLen: 200,
            outputReserve: 100,
            estimatedPromptTokens: 150,
            overheadTokens: 50
        )
        // Total = 200, usable = 100, overage = 100
        XCTAssertEqual(budget.totalEstimatedTokens, 200)
        XCTAssertEqual(budget.usableContext, 100)
        XCTAssertEqual(budget.overage, 100)
        XCTAssertTrue(budget.exceedsBudget)
    }
}

// MARK: - Prompt Assembler Tests

final class PromptAssemblerTests: XCTestCase {

    static var allTests = [
        ("testNoFilesReturnsPlainPrompt", testNoFilesReturnsPlainPrompt),
        ("testSingleFile", testSingleFile),
        ("testMultipleFiles", testMultipleFiles),
        ("testFileBoundaries", testFileBoundaries),
        ("testReferenceInstruction", testReferenceInstruction),
        ("testUserQuestionAfterFiles", testUserQuestionAfterFiles),
        ("testEmptyFileContent", testEmptyFileContent),
        ("testMultilineFileContent", testMultilineFileContent),
        ("testCustomDelimiters", testCustomDelimiters),
        ("testFormatFileBlock", testFormatFileBlock),
        ("testAssemblePromptNoFiles", testAssemblePromptNoFiles),
        ("testAssemblePromptWithFiles", testAssemblePromptWithFiles),
    ]

    private let assembler = PromptAssembler()

    func testNoFilesReturnsPlainPrompt() throws {
        let result = try assembler.assemble(
            userPrompt: "What is the capital of France?",
            files: []
        )
        XCTAssertEqual(result, "What is the capital of France?")
    }

    func testSingleFile() throws {
        let result = try assembler.assemble(
            userPrompt: "Explain this code",
            files: [
                (relativePath: "src/main.swift", content: "print(\"hello\")")
            ]
        )
        XCTAssertTrue(result.contains("<<<FILE: src/main.swift"))
        XCTAssertTrue(result.contains("print(\"hello\")"))
        XCTAssertTrue(result.contains("END_FILE>>>"))
        XCTAssertTrue(result.contains("Explain this code"))
        // File content should come before user question
        let fileRange = result.range(of: "<<<FILE:")!
        let questionRange = result.range(of: "Explain this code")!
        XCTAssertLessThan(fileRange.lowerBound, questionRange.lowerBound)
    }

    func testMultipleFiles() throws {
        let result = try assembler.assemble(
            userPrompt: "Compare these files",
            files: [
                (relativePath: "a.swift", content: "let a = 1"),
                (relativePath: "b.swift", content: "let b = 2"),
            ]
        )
        XCTAssertTrue(result.contains("<<<FILE: a.swift"))
        XCTAssertTrue(result.contains("<<<FILE: b.swift"))
        XCTAssertTrue(result.contains("let a = 1"))
        XCTAssertTrue(result.contains("let b = 2"))
        // Both files should be present
        let aRange = result.range(of: "a.swift")!
        let bRange = result.range(of: "b.swift")!
        XCTAssertLessThan(aRange.lowerBound, bRange.lowerBound)
    }

    func testFileBoundaries() throws {
        let result = try assembler.assemble(
            userPrompt: "test",
            files: [
                (relativePath: "file.txt", content: "content here")
            ]
        )
        // Verify the structure: delimiter, content, end delimiter
        XCTAssertTrue(result.contains("<<<FILE: file.txt\ncontent here\nEND_FILE>>>"))
    }

    func testReferenceInstruction() throws {
        let result = try assembler.assemble(
            userPrompt: "test",
            files: [
                (relativePath: "file.txt", content: "data")
            ]
        )
        XCTAssertTrue(result.contains("reference material"))
        XCTAssertTrue(result.contains("NOT instructions"))
    }

    func testUserQuestionAfterFiles() throws {
        let result = try assembler.assemble(
            userPrompt: "What does this do?",
            files: [
                (relativePath: "code.py", content: "import os")
            ]
        )
        let questionLabelRange = result.range(of: "User question:")!
        let questionRange = result.range(of: "What does this do?")!
        let fileEndRange = result.range(of: "END_FILE>>>")!
        // User question label should come after file end
        XCTAssertGreaterThan(questionLabelRange.lowerBound, fileEndRange.lowerBound)
        // Actual question should come after the label
        XCTAssertGreaterThan(questionRange.lowerBound, questionLabelRange.lowerBound)
    }

    func testEmptyFileContent() throws {
        let result = try assembler.assemble(
            userPrompt: "test",
            files: [
                (relativePath: "empty.txt", content: "")
            ]
        )
        XCTAssertTrue(result.contains("<<<FILE: empty.txt"))
        XCTAssertTrue(result.contains("END_FILE>>>"))
    }

    func testMultilineFileContent() throws {
        let content = "line1\nline2\nline3"
        let result = try assembler.assemble(
            userPrompt: "test",
            files: [
                (relativePath: "multi.txt", content: content)
            ]
        )
        XCTAssertTrue(result.contains("line1\nline2\nline3"))
    }

    func testCustomDelimiters() {
        let customAssembler = PromptAssembler(
            fileStartDelimiter: "===START:",
            fileEndDelimiter: "===END===",
            referenceInstruction: "Custom instruction"
        )
        let result = customAssembler.assemblePrompt(
            userPrompt: "test",
            files: [
                (relativePath: "file.txt", content: "data")
            ]
        )
        XCTAssertTrue(result.contains("===START: file.txt"))
        XCTAssertTrue(result.contains("===END==="))
        XCTAssertTrue(result.contains("Custom instruction"))
    }

    func testFormatFileBlock() {
        let block = assembler.formatFileBlock(
            relativePath: "src/app.swift",
            content: "import SwiftUI"
        )
        XCTAssertEqual(block, "<<<FILE: src/app.swift\nimport SwiftUI\nEND_FILE>>>")
    }

    func testAssemblePromptNoFiles() {
        let result = assembler.assemblePrompt(
            userPrompt: "Just a plain question",
            files: []
        )
        XCTAssertEqual(result, "Just a plain question")
    }

    func testAssemblePromptWithFiles() {
        let result = assembler.assemblePrompt(
            userPrompt: "Analyze this",
            files: [
                (relativePath: "data.json", content: "{\"key\": \"value\"}")
            ]
        )
        XCTAssertTrue(result.contains("<<<FILE: data.json"))
        XCTAssertTrue(result.contains("{\"key\": \"value\"}"))
        XCTAssertTrue(result.contains("Analyze this"))
    }
}

// MARK: - File Inspector Service Tests (Static Methods)

@MainActor
final class FileInspectorServiceStaticTests: XCTestCase {

    static var allTests = [
        ("testDetectEncodingPlainText", testDetectEncodingPlainText),
        ("testDetectEncodingBinaryNullByte", testDetectEncodingBinaryNullByte),
        ("testDetectEncodingUTF8BOM", testDetectEncodingUTF8BOM),
        ("testDetectEncodingUTF16LittleEndianBOM", testDetectEncodingUTF16LittleEndianBOM),
        ("testDetectEncodingUTF16BigEndianBOM", testDetectEncodingUTF16BigEndianBOM),
        ("testDetectEncodingLatin1", testDetectEncodingLatin1),
        ("testDetectEncodingEmptyData", testDetectEncodingEmptyData),
        ("testDetectEncodingNullByteInFirst8KB", testDetectEncodingNullByteInFirst8KB),
        ("testDetectEncodingNullByteAfter8KB", testDetectEncodingNullByteAfter8KB),
        ("testFormatByteCountZero", testFormatByteCountZero),
        ("testFormatByteCountKB", testFormatByteCountKB),
        ("testFormatByteCountMB", testFormatByteCountMB),
    ]

    func testDetectEncodingPlainText() {
        let data = Data("Hello, this is a plain text file.".utf8)
        let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
        XCTAssertFalse(isBinary)
        XCTAssertEqual(encoding, .utf8)
    }

    func testDetectEncodingBinaryNullByte() {
        var data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        data.append(0x00) // null byte
        data.append(0x48)
        let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
        XCTAssertTrue(isBinary)
        XCTAssertNil(encoding)
    }

    func testDetectEncodingUTF8BOM() {
        var data = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        data.append(Data("Hello".utf8))
        let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
        XCTAssertFalse(isBinary)
        XCTAssertEqual(encoding, .utf8)
    }

    func testDetectEncodingUTF16LittleEndianBOM() {
        var data = Data([0xFF, 0xFE]) // UTF-16 LE BOM
        data.append(Data("Hi".utf8))
        let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
        XCTAssertFalse(isBinary)
        XCTAssertEqual(encoding, .utf16LittleEndian)
    }

    func testDetectEncodingUTF16BigEndianBOM() {
        var data = Data([0xFE, 0xFF]) // UTF-16 BE BOM
        data.append(Data("Hi".utf8))
        let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
        XCTAssertFalse(isBinary)
        XCTAssertEqual(encoding, .utf16BigEndian)
    }

    func testDetectEncodingLatin1() {
        // Data with high bytes that aren't valid UTF-8 but are valid Latin-1
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xE9, 0x21]) // "Hello é!"
        let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
        XCTAssertFalse(isBinary)
        // Should fall through to ISO-8859-1 since 0xE9 alone isn't valid UTF-8
        XCTAssertEqual(encoding, .isoLatin1)
    }

    func testDetectEncodingEmptyData() {
        let data = Data()
        let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
        // Empty data: no null bytes, empty string is valid UTF-8
        XCTAssertFalse(isBinary)
        XCTAssertEqual(encoding, .utf8)
    }

    func testDetectEncodingNullByteInFirst8KB() {
        var data = Data(repeating: 0x41, count: 100) // "AAA..."
        data.append(0x00) // null byte within first 8KB
        data.append(Data(repeating: 0x42, count: 100))
        let (isBinary, _) = FileInspectorService.detectEncoding(data: data)
        XCTAssertTrue(isBinary)
    }

    func testDetectEncodingNullByteAfter8KB() {
        // Data larger than 8KB with null byte only after the 8KB check window
        var data = Data(repeating: 0x41, count: 9000) // 9KB of 'A'
        data.append(0x00) // null byte at position 9000 (after 8KB check)
        data.append(Data(repeating: 0x42, count: 100))
        let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
        // The null byte is after the 8KB check window, so it won't be detected as binary
        // by the null byte check. However, the data is all ASCII, so it should be valid UTF-8.
        XCTAssertFalse(isBinary)
        XCTAssertEqual(encoding, .utf8)
    }

    func testFormatByteCountZero() {
        let result = FileInspectorService.formatByteCount(0)
        XCTAssertEqual(result, "0 bytes")
    }

    func testFormatByteCountKB() {
        let result = FileInspectorService.formatByteCount(2048)
        // ByteCountFormatter with .file style: 2 KB
        XCTAssertTrue(result.contains("KB") || result.contains("kB"))
    }

    func testFormatByteCountMB() {
        let result = FileInspectorService.formatByteCount(1_048_576)
        XCTAssertTrue(result.contains("MB") || result.contains("Mb"))
    }
}

// MARK: - Workspace Explorer Service Tests (Pure Logic Methods)

@MainActor
final class WorkspaceExplorerServiceLogicTests: XCTestCase {

    static var allTests = [
        ("testIsWithinWorkspaceExactRoot", testIsWithinWorkspaceExactRoot),
        ("testIsWithinWorkspaceChildPath", testIsWithinWorkspaceChildPath),
        ("testIsWithinWorkspaceOutsidePath", testIsWithinWorkspaceOutsidePath),
        ("testIsWithinWorkspaceSiblingDirectory", testIsWithinWorkspaceSiblingDirectory),
        ("testIsWithinWorkspaceDotDotTraversal", testIsWithinWorkspaceDotDotTraversal),
        ("testIsWithinWorkspacePrefixTrick", testIsWithinWorkspacePrefixTrick),
        ("testIsSensitiveFileEnv", testIsSensitiveFileEnv),
        ("testIsSensitiveFilePrivateKey", testIsSensitiveFilePrivateKey),
        ("testIsSensitiveFileCredentials", testIsSensitiveFileCredentials),
        ("testIsSensitiveFileNormalSource", testIsSensitiveFileNormalSource),
        ("testIsSensitiveFileNestedEnv", testIsSensitiveFileNestedEnv),
        ("testIsSensitiveFileSecretInName", testIsSensitiveFileSecretInName),
        ("testIsSensitiveFileCredentialInName", testIsSensitiveFileCredentialInName),
        ("testIsSensitiveFilePEMExtension", testIsSensitiveFilePEMExtension),
        ("testIsSensitiveFileKeyExtension", testIsSensitiveFileKeyExtension),
        ("testExcludedDirectoryNames", testExcludedDirectoryNames),
        ("testIncludedFileExtensions", testIncludedFileExtensions),
    ]

    // Create a minimal instance for testing pure logic methods.
    // The service requires workspaceService and explorerService in init,
    // but isWithinWorkspace and isSensitiveFile don't use them.
    // We use a workaround: test the logic directly since the methods
    // are pure functions of their inputs.

    private func makeService() -> WorkspaceExplorerService {
        // We can't easily instantiate the full service in tests without
        // a real workspace. Instead, we test the static sets and
        // replicate the logic for the instance methods.
        // For now, return a service with a dummy workspace.
        let workspaceService = WorkspaceService()
        let explorerService = WorkspaceExplorerService(workspaceService: workspaceService)
        return explorerService
    }

    func testIsWithinWorkspaceExactRoot() {
        let service = makeService()
        XCTAssertTrue(service.isWithinWorkspace("/Users/test/project", resolvedRoot: "/Users/test/project"))
    }

    func testIsWithinWorkspaceChildPath() {
        let service = makeService()
        XCTAssertTrue(service.isWithinWorkspace("/Users/test/project/src/main.swift", resolvedRoot: "/Users/test/project"))
    }

    func testIsWithinWorkspaceOutsidePath() {
        let service = makeService()
        XCTAssertFalse(service.isWithinWorkspace("/Users/test/other/file.swift", resolvedRoot: "/Users/test/project"))
    }

    func testIsWithinWorkspaceSiblingDirectory() {
        let service = makeService()
        // /Users/test/project2 is NOT inside /Users/test/project
        XCTAssertFalse(service.isWithinWorkspace("/Users/test/project2/file.swift", resolvedRoot: "/Users/test/project"))
    }

    func testIsWithinWorkspaceDotDotTraversal() {
        let service = makeService()
        // Even though the string prefix matches, ".." components should be rejected
        XCTAssertFalse(service.isWithinWorkspace("/Users/test/project/../etc/passwd", resolvedRoot: "/Users/test/project"))
    }

    func testIsWithinWorkspacePrefixTrick() {
        let service = makeService()
        // /Users/test/project-evil should NOT match /Users/test/project
        // because the normalized root is "/Users/test/project/" and
        // "/Users/test/project-evil" doesn't start with that
        XCTAssertFalse(service.isWithinWorkspace("/Users/test/project-evil/file.swift", resolvedRoot: "/Users/test/project"))
    }

    func testIsSensitiveFileEnv() {
        let service = makeService()
        XCTAssertTrue(service.isSensitiveFile(".env"))
        XCTAssertTrue(service.isSensitiveFile("config/.env"))
        XCTAssertTrue(service.isSensitiveFile(".env.local"))
        XCTAssertTrue(service.isSensitiveFile(".env.production"))
    }

    func testIsSensitiveFilePrivateKey() {
        let service = makeService()
        XCTAssertTrue(service.isSensitiveFile("id_rsa"))
        XCTAssertTrue(service.isSensitiveFile("keys/id_rsa"))
        XCTAssertTrue(service.isSensitiveFile("id_ed25519"))
    }

    func testIsSensitiveFileCredentials() {
        let service = makeService()
        XCTAssertTrue(service.isSensitiveFile("credentials.json"))
        XCTAssertTrue(service.isSensitiveFile("secrets.yml"))
        XCTAssertTrue(service.isSensitiveFile("api_key.txt"))
    }

    func testIsSensitiveFileNormalSource() {
        let service = makeService()
        XCTAssertFalse(service.isSensitiveFile("main.swift"))
        XCTAssertFalse(service.isSensitiveFile("src/app.js"))
        XCTAssertFalse(service.isSensitiveFile("README.md"))
        XCTAssertFalse(service.isSensitiveFile("config.json"))
    }

    func testIsSensitiveFileNestedEnv() {
        let service = makeService()
        XCTAssertTrue(service.isSensitiveFile("subdir/.env"))
        XCTAssertTrue(service.isSensitiveFile("a/b/c/.env"))
    }

    func testIsSensitiveFileSecretInName() {
        let service = makeService()
        XCTAssertTrue(service.isSensitiveFile("my_secrets.txt"))
        XCTAssertTrue(service.isSensitiveFile("secret_config.json"))
    }

    func testIsSensitiveFileCredentialInName() {
        let service = makeService()
        XCTAssertTrue(service.isSensitiveFile("user_credentials.csv"))
    }

    func testIsSensitiveFilePEMExtension() {
        let service = makeService()
        XCTAssertTrue(service.isSensitiveFile("certificate.pem"))
        XCTAssertTrue(service.isSensitiveFile("cert/key.pem"))
    }

    func testIsSensitiveFileKeyExtension() {
        let service = makeService()
        XCTAssertTrue(service.isSensitiveFile("server.key"))
        XCTAssertTrue(service.isSensitiveFile("tls/server.key"))
    }

    func testExcludedDirectoryNames() {
        XCTAssertTrue(WorkspaceExplorerService.excludedDirectoryNames.contains(".git"))
        XCTAssertTrue(WorkspaceExplorerService.excludedDirectoryNames.contains("node_modules"))
        XCTAssertTrue(WorkspaceExplorerService.excludedDirectoryNames.contains("DerivedData"))
        XCTAssertTrue(WorkspaceExplorerService.excludedDirectoryNames.contains(".build"))
        XCTAssertTrue(WorkspaceExplorerService.excludedDirectoryNames.contains("build"))
        XCTAssertTrue(WorkspaceExplorerService.excludedDirectoryNames.contains("dist"))
        XCTAssertFalse(WorkspaceExplorerService.excludedDirectoryNames.contains("src"))
        XCTAssertFalse(WorkspaceExplorerService.excludedDirectoryNames.contains("tests"))
    }

    func testIncludedFileExtensions() {
        XCTAssertTrue(WorkspaceExplorerService.includedFileExtensions.contains("swift"))
        XCTAssertTrue(WorkspaceExplorerService.includedFileExtensions.contains("js"))
        XCTAssertTrue(WorkspaceExplorerService.includedFileExtensions.contains("ts"))
        XCTAssertTrue(WorkspaceExplorerService.includedFileExtensions.contains("py"))
        XCTAssertTrue(WorkspaceExplorerService.includedFileExtensions.contains("md"))
        XCTAssertTrue(WorkspaceExplorerService.includedFileExtensions.contains("json"))
        XCTAssertFalse(WorkspaceExplorerService.includedFileExtensions.contains("png"))
        XCTAssertFalse(WorkspaceExplorerService.includedFileExtensions.contains("exe"))
    }
}

// MARK: - File Attachment Model Tests

final class FileAttachmentModelTests: XCTestCase {

    static var allTests = [
        ("testAttachmentCreation", testAttachmentCreation),
        ("testAttachmentHashable", testAttachmentHashable),
        ("testAttachmentIdentifiable", testAttachmentIdentifiable),
    ]

    func testAttachmentCreation() {
        let attachment = FileAttachment(
            resolvedPath: "/Users/test/project/src/main.swift",
            relativePath: "src/main.swift",
            fileName: "main.swift",
            fileSize: 1024,
            estimatedTokens: 256
        )
        XCTAssertEqual(attachment.resolvedPath, "/Users/test/project/src/main.swift")
        XCTAssertEqual(attachment.relativePath, "src/main.swift")
        XCTAssertEqual(attachment.fileName, "main.swift")
        XCTAssertEqual(attachment.fileSize, 1024)
        XCTAssertEqual(attachment.estimatedTokens, 256)
        XCTAssertFalse(attachment.isSensitive)
    }

    func testAttachmentHashable() {
        let attachment1 = FileAttachment(
            id: UUID(),
            resolvedPath: "/path/file.swift",
            relativePath: "file.swift",
            fileName: "file.swift",
            fileSize: 100,
            estimatedTokens: 25
        )
        let attachment2 = FileAttachment(
            id: attachment1.id,
            resolvedPath: "/path/file.swift",
            relativePath: "file.swift",
            fileName: "file.swift",
            fileSize: 100,
            estimatedTokens: 25
        )
        XCTAssertEqual(attachment1, attachment2)
    }

    func testAttachmentIdentifiable() {
        let attachment = FileAttachment(
            resolvedPath: "/path/file.swift",
            relativePath: "file.swift",
            fileName: "file.swift",
            fileSize: 100,
            estimatedTokens: 25
        )
        XCTAssertNotNil(attachment.id)
    }
}

// MARK: - Context Budget Model Tests

final class ContextBudgetModelTests: XCTestCase {

    static var allTests = [
        ("testBudgetProperties", testBudgetProperties),
        ("testBudgetNoMaxLen", testBudgetNoMaxLen),
        ("testBudgetZeroMaxLen", testBudgetZeroMaxLen),
    ]

    func testBudgetProperties() {
        let budget = ContextBudget(
            maxModelLen: 4096,
            outputReserve: 1024,
            estimatedPromptTokens: 500,
            overheadTokens: 50
        )
        XCTAssertEqual(budget.maxModelLen, 4096)
        XCTAssertEqual(budget.outputReserve, 1024)
        XCTAssertEqual(budget.estimatedPromptTokens, 500)
        XCTAssertEqual(budget.overheadTokens, 50)
        XCTAssertEqual(budget.totalEstimatedTokens, 550)
        XCTAssertEqual(budget.usableContext, 3072)
        XCTAssertFalse(budget.exceedsBudget)
        XCTAssertEqual(budget.overage, 0)
        XCTAssertTrue(budget.hasReliableMetadata)
    }

    func testBudgetNoMaxLen() {
        let budget = ContextBudget(
            maxModelLen: nil,
            outputReserve: 1024,
            estimatedPromptTokens: 500,
            overheadTokens: 50
        )
        XCTAssertNil(budget.maxModelLen)
        XCTAssertNil(budget.usableContext)
        XCTAssertFalse(budget.exceedsBudget)
        XCTAssertEqual(budget.overage, 0)
        XCTAssertFalse(budget.hasReliableMetadata)
    }

    func testBudgetZeroMaxLen() {
        let budget = ContextBudget(
            maxModelLen: 0,
            outputReserve: 1024,
            estimatedPromptTokens: 100,
            overheadTokens: 50
        )
        // maxModelLen is 0, which is not > 0, so not reliable
        XCTAssertFalse(budget.hasReliableMetadata)
        // usable = max(0, 0 - 1024) = 0
        XCTAssertEqual(budget.usableContext, 0)
        // total = 150 > 0, so exceeds
        XCTAssertTrue(budget.exceedsBudget)
    }
}
