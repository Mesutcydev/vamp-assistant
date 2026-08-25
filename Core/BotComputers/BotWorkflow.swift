import Foundation

struct BotWorkflowNodeTemplate: Equatable, Sendable {
    var key: String
    var specialistID: String
    var specialistName: String
    var prompt: String
    var dependencyKeys: [String]
    var phase: BotEvidencePhase
    var acceptanceCriteria: [String]
    var requiredEvidence: [BotEvidenceKind]
}

struct BotWorkflowPlan: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var rationale: String
    var nodes: [BotWorkflowNodeTemplate]
}

/// Deterministic outer routing keeps safety, budgets, and topology in code.
/// Models still reason inside each bounded specialist run.
enum BotAdaptivePlanner {
    static func plan(prompt: String) -> BotWorkflowPlan {
        let lower = prompt.lowercased()
        let needsResearch = containsAny(lower, [
            "research", "latest", "current", "compare", "sources", "documentation", "web search"
        ])
        let needsNavigation = containsAny(lower, [
            "browser", "website", "web app", "navigate", "login", "form", "click", "page"
        ])
        let needsBuild = containsAny(lower, [
            "build", "implement", "fix", "code", "refactor", "feature", "app", "project"
        ])
        let reviewOnly = !needsBuild && containsAny(lower, [
            "review", "audit", "regression", "inspect diff", "security review"
        ])

        var nodes: [BotWorkflowNodeTemplate] = []
        if needsResearch {
            nodes.append(node(
                "research", "researcher", "Researcher", prompt,
                "Return primary-source evidence, constraints, and an implementation brief.",
                phase: .research,
                criteria: ["Primary sources are identified", "Constraints and uncertainty are explicit"],
                evidence: [.sources]))
        }
        if needsNavigation {
            nodes.append(node(
                "navigate", "navigator", "Navigator", prompt,
                "Observe the current browser flow, capture reproducible evidence, and avoid unrelated mutations.",
                phase: .navigation,
                criteria: ["The observed flow is reproducible", "Visible behavior is captured without unrelated mutation"],
                evidence: [.execution]))
        }
        if needsBuild || (!needsResearch && !needsNavigation && !reviewOnly) {
            let dependencies = nodes.map(\.key)
            nodes.append(node(
                "build", "builder", "Builder", prompt,
                "Implement completely, produce changed-file and verification artifacts, and preserve unrelated work.",
                dependencies: dependencies,
                phase: .code,
                criteria: ["The requested outcome is implemented", "Changed files and checks are reported"],
                evidence: [.execution, .verification]))
            nodes.append(node(
                "verify", "reviewer", "Reviewer", prompt,
                "Review the completed implementation independently. Check correctness, regressions, tests, safety, and report pass or concrete findings.",
                dependencies: ["build"],
                phase: .review,
                criteria: ["The implementation is reviewed independently", "Regressions, safety, and test evidence are assessed"],
                evidence: [.review]))
        } else if reviewOnly {
            nodes.append(node(
                "review", "reviewer", "Reviewer", prompt,
                "Perform an evidence-first review and return prioritized findings.",
                phase: .review,
                criteria: ["Findings are evidence-backed and prioritized", "Unverified assumptions are labeled"],
                evidence: [.review]))
        }

        return BotWorkflowPlan(
            id: UUID(), title: String(prompt.prefix(80)),
            rationale: rationale(
                research: needsResearch, navigation: needsNavigation,
                build: needsBuild, reviewOnly: reviewOnly),
            nodes: nodes)
    }

    private static func node(
        _ key: String, _ id: String, _ name: String, _ prompt: String,
        _ contract: String,
        dependencies: [String] = [],
        phase: BotEvidencePhase,
        criteria: [String],
        evidence: [BotEvidenceKind]
    ) -> BotWorkflowNodeTemplate {
        BotWorkflowNodeTemplate(
            key: key, specialistID: id, specialistName: name,
            prompt: "\(prompt)\n\nOrchestration contract:\n\(contract)\n\nCompletion criteria:\n"
                + criteria.map { "- \($0)" }.joined(separator: "\n"),
            dependencyKeys: dependencies,
            phase: phase,
            acceptanceCriteria: criteria,
            requiredEvidence: evidence)
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func rationale(
        research: Bool, navigation: Bool, build: Bool, reviewOnly: Bool
    ) -> String {
        var values: [String] = []
        if research { values.append("primary-source research") }
        if navigation { values.append("browser observation") }
        if build { values.append("implementation with independent verification") }
        if reviewOnly { values.append("independent review") }
        return values.isEmpty ? "bounded implementation with verification" : values.joined(separator: ", ")
    }
}
