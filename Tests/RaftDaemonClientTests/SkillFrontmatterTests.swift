import Foundation
import Testing
import RaftDaemonClient

private func md(_ lines: String...) -> String {
    (["---"] + lines + ["---", "", "# Body", "prose"]).joined(separator: "\n")
}

private func parse(_ content: String) -> [String: String] {
    SkillFrontmatter.parse(content)
}

// The line reader this module replaced, kept only as a reference oracle.
private func legacyLineReader(_ content: String) -> [String: String] {
    var result: [String: String] = [:]
    guard let start = content.range(of: "^---\\n", options: .regularExpression),
          let end = content.range(of: "\\n---", options: .regularExpression, range: start.upperBound..<content.endIndex)
    else { return result }
    let body = String(content[start.upperBound..<end.lowerBound])
    for line in body.components(separatedBy: "\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        result[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    return result
}

@Test func literalBlockKeepsItsLinesAndNotTheMarker() {
    let fm = parse(md("name: deploy", "description: |", "  Deploy the service.", "  Use after a green build.", "user-invocable: true"))
    #expect(fm["description"] != "|")
    #expect(fm["description"] == "Deploy the service.\nUse after a green build.\n")
    #expect(fm["user-invocable"] == "true")
    #expect(fm["name"] == "deploy")
}

@Test func foldedBlockFoldsNewlinesIntoSpaces() {
    let fm = parse(md("description: >", "  Deploy the service", "  after a green build.", "name: deploy"))
    #expect(fm["description"] != ">")
    #expect(fm["description"] == "Deploy the service after a green build.\n")
    #expect(fm["name"] == "deploy")
}

@Test func foldedBlockTurnsABlankLineIntoAParagraphBreak() {
    let fm = parse(md("description: >", "  First paragraph here.", "", "  Second paragraph here."))
    #expect(fm["description"] == "First paragraph here.\nSecond paragraph here.\n")
}

@Test func blockChompingIndicatorsAreNotTheValue() {
    for header in ["|-", "|+", ">-", ">+"] {
        let fm = parse(md("description: \(header)", "  Body line."))
        #expect(fm["description"] != header)
        #expect(fm["description"]?.range(of: "^Body line\\.\\n*$", options: .regularExpression) != nil)
    }
}

@Test func stripClipAndKeepDifferInTrailingNewlines() {
    func value(_ header: String) -> String {
        parse(md("description: \(header)", "  Body line.", "", ""))["description"] ?? ""
    }
    let strip = value("|-")
    let clip = value("|")
    let keep = value("|+")
    #expect(strip == "Body line.")
    #expect(clip == "Body line.\n")
    #expect(keep == "Body line.\n\n\n")
    #expect(strip != clip)
    #expect(clip != keep)
}

@Test func foldedBlocksChompTheSameThreeWays() {
    func value(_ header: String) -> String {
        parse(md("description: \(header)", "  One", "  two.", "", ""))["description"] ?? ""
    }
    #expect(value(">-") == "One two.")
    #expect(value(">") == "One two.\n")
    #expect(value(">+") == "One two.\n\n\n")
}

@Test func explicitIndentationIndicatorIsHonoured() {
    let fm = parse(md("description: |2", "  Body line.", "    Indented more."))
    #expect(fm["description"] == "Body line.\n  Indented more.\n")
}

@Test func doubleQuotedDescriptionWithColonKeepsQuotesRemoved() {
    let fm = parse(md("description: \"Use when: the build is red\""))
    #expect(fm["description"] == "Use when: the build is red")
    #expect(!(fm["description"] ?? "").contains("\""))
}

@Test func singleQuotedDescriptionUnescapesDoubledQuotes() {
    let fm = parse(md("description: 'It''s ready: go'"))
    #expect(fm["description"] == "It's ready: go")
}

@Test func commentAfterQuotedScalarIsStrippedAndHashInsideKept() {
    #expect(parse(md("description: \"Deploy it\" # internal note"))["description"] == "Deploy it")
    #expect(parse(md("description: 'Deploy it' # internal note"))["description"] == "Deploy it")
    #expect(parse(md("description: \"Fixes issue #42\""))["description"] == "Fixes issue #42")
    #expect(parse(md("description: \"Fixes #42\" # tracked"))["description"] == "Fixes #42")
}

@Test func escapedQuotesInsideDoubleQuotedDescriptionAreUnescaped() {
    let fm = parse(md("description: \"He said \\\"go\\\" twice\""))
    #expect(fm["description"] == "He said \"go\" twice")
}

@Test func plainSingleLineDescriptionIsUnchanged() {
    let fm = parse(md("name: codex-skill", "description: CODEX_HOME scoped skill", "user-invocable: false"))
    #expect(fm["name"] == "codex-skill")
    #expect(fm["description"] == "CODEX_HOME scoped skill")
    #expect(fm["user-invocable"] == "false")
}

@Test func unquotedPlainValueKeepsTextAfterItsFirstColon() {
    #expect(parse(md("description: Use this: always"))["description"] == "Use this: always")
}

@Test func noFrontmatterYieldsNoKeys() {
    #expect(parse("# Just a heading\ntext").isEmpty)
    #expect(parse("").isEmpty)
}

@Test func crlfFrontmatterParsesLikeLf() {
    let lf = parse(md("description: |", "  Line one.", "  Line two."))
    let crlf = parse(["---", "description: |", "  Line one.", "  Line two.", "---", "", "# Body"].joined(separator: "\r\n"))
    #expect(crlf == lf)
}

@Test func trailingCommentStrippedFromPlainScalarButBareHashKept() {
    #expect(parse(md("description: Deploy it # internal note"))["description"] == "Deploy it")
    #expect(parse(md("description: Build for C# targets"))["description"] == "Build for C# targets")
}

@Test func commentLineAndBlankLineInFrontmatterAreIgnored() {
    let fm = parse(md("# a comment", "", "description: Deploy it", "name: deploy"))
    #expect(fm["description"] == "Deploy it")
    #expect(fm["name"] == "deploy")
}

@Test func unsupportedSyntaxFailsClosed() {
    let unsupported = [
        ("anchor", "description: &a Reusable text"),
        ("alias", "description: *a"),
        ("tag", "description: !!str Tagged"),
        ("flow sequence", "description: [one, two]"),
        ("flow mapping", "description: {a: b}"),
        ("complex mapping key", "description: ? weird"),
        ("reserved @", "description: @reserved"),
        ("reserved backtick", "description: `reserved"),
        ("directive %", "description: %YAML 1.2"),
        ("sequence entry", "description: - first"),
        ("unterminated double quote", "description: \"unclosed"),
        ("unterminated single quote", "description: 'unclosed"),
        ("malformed block header", "description: |junk"),
    ]
    for (label, line) in unsupported {
        let fm = parse(["---", line, "---", "", "body"].joined(separator: "\n"))
        #expect(fm["description"] == "", "\(label)")
    }
}

@Test func failingClosedDoesNotStopTheRestFromParsing() {
    let fm = parse(["---", "description: &anchor text", "name: still-read", "user-invocable: true", "---", "", "body"].joined(separator: "\n"))
    #expect(fm["description"] == "")
    #expect(fm["name"] == "still-read")
    #expect(fm["user-invocable"] == "true")
}

@Test func indicatorCharacterInsidePlainScalarIsAllowed() {
    let fm = parse(["---", "description: Deploy a&b, build [x] and {y}", "---", "", "body"].joined(separator: "\n"))
    #expect(fm["description"] == "Deploy a&b, build [x] and {y}")
}

@Test func eachFixDiffersFromTheOldReader() {
    let fixed: [(String, String, String)] = [
        ("literal block", md("description: |", "  One.", "  Two."), "One.\nTwo.\n"),
        ("folded block", md("description: >", "  One", "  two."), "One two.\n"),
        ("chomp strip", md("description: |-", "  One."), "One."),
        ("chomp keep", md("description: |+", "  One.", "", ""), "One.\n\n\n"),
        ("explicit indent", md("description: |2", "  One.", "    Two."), "One.\n  Two.\n"),
        ("double-quoted with colon", md("description: \"Use when: red\""), "Use when: red"),
        ("single-quoted unescape", md("description: 'It''s red'"), "It's red"),
        ("escaped quotes", md("description: \"He said \\\"go\\\"\""), "He said \"go\""),
        ("quoted then comment", md("description: \"Deploy it\" # note"), "Deploy it"),
        ("plain trailing comment", md("description: Deploy it # note"), "Deploy it"),
        ("anchor fails closed", md("description: &a text"), ""),
        ("flow sequence fails closed", md("description: [a, b]"), ""),
        ("tag fails closed", md("description: !!str x"), ""),
    ]
    for (label, source, expected) in fixed {
        #expect(parse(source)["description"] == expected, "\(label)")
        #expect(legacyLineReader(source)["description"] != expected, "\(label) must differ from the old reader")
    }
}

@Test func preservedCasesAgreeWithTheOldReader() {
    let preserved = [md("description: CODEX_HOME scoped skill"), md("description: Use this: always"), md("description: Build for C# targets")]
    for source in preserved {
        #expect(parse(source)["description"] == legacyLineReader(source)["description"])
    }
}

@Test func nestedDescriptionDoesNotOverrideTheTopLevelOne() {
    let fm = parse(md("description: real one", "user-invocable: false", "examples:", "  description: nested one", "  user-invocable: true"))
    #expect(fm["description"] == "real one")
    #expect(fm["user-invocable"] == "false")
}

@Test func nestedUserInvocableCannotRaiseATopLevelFalse() {
    let fm = parse(md("user-invocable: false", "meta:", "  user-invocable: true"))
    #expect(fm["user-invocable"] == "false")
}

@Test func keyWhoseOnlyContentIsANestedMappingFailsClosed() {
    let fm = parse(md("name: s", "metadata:", "  description: nested only"))
    #expect(fm["description"] == nil)
    #expect(fm["metadata"] == "")
    #expect(fm["name"] == "s")
}

@Test func nestingDeeperThanOneLevelIsIgnoredToo() {
    let fm = parse(md("description: top", "a:", "  b:", "    description: deep", "    user-invocable: true"))
    #expect(fm["description"] == "top")
    #expect(fm["user-invocable"] == nil)
}

@Test func blockScalarBodyIsConsumedAndNotMistakenForNesting() {
    let fm = parse(md("description: |", "  line one", "  key-like: not a key", "user-invocable: true"))
    #expect(fm["description"] == "line one\nkey-like: not a key\n")
    #expect(fm["user-invocable"] == "true")
    #expect(fm["key-like"] == nil)
}

@Test func runOfBlankLinesYieldsOneBreakEach() {
    #expect(parse(md("description: >", "  alpha", "", "  beta"))["description"] == "alpha\nbeta\n")
    #expect(parse(md("description: >", "  alpha", "", "", "  beta"))["description"] == "alpha\n\nbeta\n")
    #expect(parse(md("description: >", "  alpha", "", "", "", "  beta"))["description"] == "alpha\n\n\nbeta\n")
}

@Test func singleBreakBetweenEquallyIndentedLinesFoldsToSpace() {
    #expect(parse(md("description: >", "  alpha", "  beta"))["description"] == "alpha beta\n")
}

@Test func moreIndentedLineKeepsBreaksOnBothSides() {
    #expect(parse(md("description: >", "  alpha", "    code", "  omega"))["description"] == "alpha\n  code\nomega\n")
}

@Test func blankLineBeforeMoreIndentedParagraphAddsToStructuralBreak() {
    #expect(parse(md("description: >", "  alpha", "", "    code", "  omega"))["description"] == "alpha\n\n  code\nomega\n")
}

@Test func invalidIndentationIndicatorsFailClosed() {
    for header in ["|0", ">0", "|10", ">99", "|-0"] {
        #expect(parse(md("description: \(header)", "  hello"))["description"] == "", "\(header)")
    }
}

@Test func validIndicatorsOneThroughNineAreAccepted() {
    #expect(parse(md("description: |1", " hello"))["description"] == "hello\n")
}

@Test func rootCommentCannotEraseIndentedMetadata() {
    #expect(parse(md("# comment", "  description: hello"))["description"] == "hello")
}

@Test func commentIndentedDeeperThanKeysChangesNothing() {
    #expect(parse(md("description: a", "  # deep comment"))["description"] == "a")
}

@Test func lineWithNoColonCannotSetTheLevel() {
    #expect(parse(md("just text", "  description: hello"))["description"] == "hello")
}

@Test func colonInsideBlockBodyDoesNotSetTheLevel() {
    let fm = parse(md("description: |", "  a: b", "user-invocable: true"))
    #expect(fm["user-invocable"] == "true")
    #expect(fm["a"] == nil)
}

@Test func documentWithAllKeysIndentedStillParses() {
    let fm = parse(md("  description: x", "  name: y"))
    #expect(fm["description"] == "x")
    #expect(fm["name"] == "y")
}

@Test func frontmatterOfCommentsAloneYieldsNoKeys() {
    #expect(parse(md("# just a comment")).isEmpty)
}

@Test func foldedLeadingBlankBecomesLeadingBreak() {
    #expect(parse(md("description: >", "", "  alpha"))["description"] == "\nalpha\n")
}

@Test func foldedTwoLeadingBlanksBecomeTwoBreaks() {
    #expect(parse(md("description: >", "", "", "  alpha"))["description"] == "\n\nalpha\n")
}

@Test func literalLeadingBlankIsPreservedToo() {
    #expect(parse(md("description: |", "", "  alpha"))["description"] == "\nalpha\n")
}

@Test func blockBodyOfOnlyBlankLinesYieldsEmptyString() {
    #expect(parse(md("description: >", "", ""))["description"] == "")
    #expect(parse(md("description: |", "", ""))["description"] == "")
}
