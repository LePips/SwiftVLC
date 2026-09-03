import XCTest

extension ShowcaseIOSTestCase {
  /// Adds a machine-readable payload that the physical-device runner turns
  /// into candidate-bound qualification evidence. Identity fields are added
  /// by the host after exporting the xcresult attachment; a test process must
  /// never guess which source tree or signed app bundle launched it.
  func attachQualificationEvidence(
    _ suppliedPayload: [String: Any],
    scenario: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard
      let sessionBinding = qualificationSessionBinding,
      let candidateBinding = observedCandidateRuntimeBinding,
      candidateBinding == expectedCandidateRuntimeBinding
    else {
      XCTFail(
        "Qualification evidence has no verified session/candidate runtime binding",
        file: file,
        line: line
      )
      return
    }
    if app.state == .runningForeground {
      observeQualificationCandidateRuntimeBindingIfRequired(file: file, line: line)
      guard observedCandidateRuntimeBinding == candidateBinding else {
        XCTFail(
          "Qualification candidate runtime binding changed before attachment",
          file: file,
          line: line
        )
        return
      }
    }
    if
      let embeddedScenario = suppliedPayload["scenario"],
      embeddedScenario as? String != scenario {
      XCTFail(
        "Qualification evidence scenario does not match \(scenario)",
        file: file,
        line: line
      )
      return
    }
    var payload = suppliedPayload
    payload["formatVersion"] = payload["formatVersion"] ?? 1
    payload["scenario"] = scenario
    payload["qualificationSessionBinding"] = sessionBinding
    payload["candidateRuntimeBinding"] = candidateBinding
    guard JSONSerialization.isValidJSONObject(payload) else {
      XCTFail("Qualification evidence is not valid JSON", file: file, line: line)
      return
    }
    do {
      let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
      )
      let attachment = XCTAttachment(
        data: data,
        uniformTypeIdentifier: "public.json"
      )
      attachment.name = "qualification-\(scenario).json"
      attachment.lifetime = .keepAlways
      add(attachment)
    } catch {
      XCTFail(
        "Could not encode qualification evidence: \(error)",
        file: file,
        line: line
      )
    }
  }

  /// Re-reads the candidate-owned accessibility proof after every launch. A
  /// value injected only into the test runner cannot satisfy this check.
  func observeQualificationCandidateRuntimeBindingIfRequired(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let expected = expectedCandidateRuntimeBinding else { return }
    let proof = app.descendants(matching: .any)[
      AccessibilityID.Qualification.candidateRuntimeBinding
    ].firstMatch
    guard proof.waitForExistence(timeout: 10) else {
      XCTFail(
        "The running candidate exposed no signed runtime binding",
        file: file,
        line: line
      )
      return
    }
    guard
      Self.isLowercaseSHA256(proof.label),
      proof.label == expected
    else {
      XCTFail(
        "The running candidate runtime binding differs from the signed candidate metadata",
        file: file,
        line: line
      )
      return
    }
    if let observedCandidateRuntimeBinding {
      XCTAssertEqual(
        observedCandidateRuntimeBinding,
        proof.label,
        "The candidate runtime binding changed between launches",
        file: file,
        line: line
      )
    }
    observedCandidateRuntimeBinding = proof.label
  }

  static func requiredQualificationBinding(
    environment: String,
    description: String
  )
    throws -> String {
    let value = try XCTUnwrap(
      ProcessInfo.processInfo.environment[environment],
      "Missing \(description) binding in \(environment)"
    )
    guard isLowercaseSHA256(value) else {
      XCTFail("Invalid \(description) binding in \(environment)")
      throw QualificationRuntimeBindingError.invalid(description)
    }
    return value
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    }
  }
}

private enum QualificationRuntimeBindingError: Error {
  case invalid(String)
}
