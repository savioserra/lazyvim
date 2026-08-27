import assert from "node:assert/strict";
import test from "node:test";
import { productivePhase, rendererRowText, transcriptHint } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/renderer/ui.mjs";

test("renderer row shows display role access mode and productive phase without liveness/current tool", () => {
	const node = { label: "UX QA", role: "quality assurance", accessMode: "read-only", state: "running", productivePhase: "testing", currentTool: "bash", bridgeReady: true };
	const text = rendererRowText({ node, depth: 0 }, 120);
	assert.match(text, /UX QA · quality assurance · read-only · testing/);
	assert.doesNotMatch(text, /bash|bridgeReady|running/);
	assert.equal(productivePhase({ state: "running", bridgeReady: true }), "working", "liveness must not replace productive state");
	assert.equal(productivePhase({ state: "running", productivePhase: "reviewing" }), "reviewing");
});

test("renderer narrow rows retain semantics and transcript hint is fullscreen-only", () => {
	const node = { label: "Architecture Review", role: "review", accessMode: "writer", state: "paused", fullscreenTranscript: true };
	const text = rendererRowText({ node, depth: 0 }, 42);
	assert.ok(text.length <= 39);
	assert.match(text, /Architecture Review/);
	assert.match(text, /review/);
	assert.equal(transcriptHint(node), "transcript: wheel · PgUp/PgDn");
	assert.equal(transcriptHint({ ...node, fullscreenTranscript: false }), "");
});
