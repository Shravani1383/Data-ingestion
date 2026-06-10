# Evaluation Semantics for Open Prompt & Tool Responses

**Epic:** Upgrade Evaluation Service Groundedness Models for Open Prompt & Web Grounding
**Ticket:** LLMPS-6476
**Status:** In Progress
**Owner:** [Your Name]
**Reviewers:** Ethan Alberto, Alistair Boyer
**Last Updated:** June 2026

---

## 1. Purpose & Problem Statement

The Productivity Suite chatbot currently supports three distinct response modes:

- **RAG (Document Q&A)** — response grounded in retrieved documents
- **Open Prompt** — direct LLM response with no document context
- **Agentic Tools** — response generated via tool invocations (e.g. web search, glossary lookup)

Our existing Evaluation Service was designed around the RAG mode, where groundedness is well-defined: *did the response faithfully reflect the retrieved document context?*

The problem is that **this definition does not translate cleanly to Open Prompt or Agentic Tool responses**:

- In **Open Prompt** mode, there is no source document to ground against. Applying a groundedness score here would either always return N/A or produce meaningless results.
- In **Agentic Tool** mode, the "context" is not a document — it is the output of one or more tool calls (e.g. web search results). Groundedness must be redefined as: *did the response faithfully use what the tools returned?*

This page documents the agreed approach for how the Evaluation Service should behave across all three modes, what technology we are adopting to enable this, and how it integrates with the existing architecture.

---

## 2. Decision Summary

After reviewing options (see Section 5), the agreed approach is:

| Response Mode | Groundedness Definition | Eval Rubric | Groundedness Score |
|---|---|---|---|
| RAG | vs. retrieved documents | Existing (faithfulness + context relevance) | ✅ Scored as today |
| Open Prompt | N/A — no source exists | Relevance, coherence, instruction following | ❌ Marked N/A |
| Agentic (Tool Call) | vs. tool outputs | Query formulation, tool utilisation, answer groundedness | ✅ Scored vs tool output |

The key principle: **groundedness is not removed for agentic responses — the source shifts from a document to the tool output.**

---

## 3. Technology: Langfuse

### 3.1 What is Langfuse?

Langfuse is an **open-source LLM engineering and observability platform**. It provides structured tracing of every LLM interaction — capturing inputs, outputs, tool calls, intermediate steps, latencies, and token usage — and exposes these traces to downstream evaluation and scoring systems.

It is:
- Fully open source (Apache 2.0 licensed)
- Self-hostable — no data leaves our infrastructure
- Natively integrated with LangGraph via a callback handler
- Compatible with OpenAI SDK via a drop-in wrapper

### 3.2 Why Langfuse for This Problem?

The core challenge in evaluating Open Prompt and Agentic responses is **getting the right data to the Evaluation Service**. Specifically:

- For Open Prompt: we need to capture what the system prompt said, what the user asked, and what the model returned — with a mode tag so the Eval Service knows to apply a different rubric.
- For Agentic Tools: we need to capture each tool call's input and output as structured spans, so the Eval Service can treat tool outputs as the grounding context.

Langfuse solves this by **sitting inside the Chat Service as a trace collection layer** — it automatically captures all of this data without requiring changes to the Evaluation Service itself.

### 3.3 What Langfuse Is Not

Langfuse is **not** a replacement for the Evaluation Service. It does not score responses. Its role is:

> Capture what happened → surface it to the Evaluation Service → receive scores back

The Evaluation Service remains the scoring authority. Langfuse is the observability and data pipeline layer between the Chat Service and the Evaluation Service.

---

## 4. Architecture

### 4.1 Where Langfuse Sits

```
┌──────────────────────────────────────────────────┐
│                  CHAT SERVICE                     │
│                                                   │
│   User Request                                    │
│        ↓                                          │
│   ┌─────────────────────────────────────┐         │
│   │   LangGraph Agent (Agentic mode)    │         │
│   │   OR                                │  ← Langfuse │
│   │   Direct OpenAI call (Open Prompt)  │   instrumented │
│   └─────────────────────────────────────┘   here  │
│        ↓                                          │
│   Response to User                                │
└──────────────────────────────────────────────────┘
         ↓ async, non-blocking
┌──────────────────────────────────────────────────┐
│         LANGFUSE (self-hosted)                    │
│  Stores: traces, spans, tool call I/O, metadata  │
└──────────────────────────────────────────────────┘
         ↓ webhook / SDK polling
┌──────────────────────────────────────────────────┐
│         EVALUATION SERVICE                        │
│  Receives trace → applies mode-based rubric       │
│  → posts scores back to Langfuse                 │
└──────────────────────────────────────────────────┘
```

**Langfuse is instrumented inside the Chat Service only.** No changes are required to the Evaluation Service interface — it receives a structured payload and returns scores, same as today.

### 4.2 What Each Mode Produces in Langfuse

**Open Prompt trace:**
```
Trace: open_prompt_call
├── metadata: { mode: "open_prompt" }
├── input:  { system_prompt, user_message }
└── output: "LLM response text"
    (no spans — single LLM call, no tool steps)
```

**Agentic Tool trace (e.g. Web Search):**
```
Trace: agent_run
├── metadata: { mode: "agentic", feature: "web_search" }
├── Span: OrchestratorNode
│     input:  user query
│     output: routing decision
├── Span: WebSearchSubAgent
│     ├── Tool call: web_search("query v1") → results
│     ├── Tool call: web_search("query v2") → results   ← refinement
│     └── LLM call: synthesise results → final answer
└── output: final answer to user
```

**RAG trace (existing, unchanged):**
```
Trace: rag_call
├── metadata: { mode: "rag" }
├── Span: Retrieval → retrieved chunks
└── Span: Generation → grounded response
```

### 4.3 How Instrumentation Works

**Agentic / LangGraph mode** — single callback handler on graph invocation:

```python
from langfuse.callback import CallbackHandler

langfuse_handler = CallbackHandler(
    session_id=session_id,
    metadata={"mode": "agentic", "feature": "web_search"}
)

result = langgraph_agent.invoke(
    input={"messages": [...]},
    config={"callbacks": [langfuse_handler]}
)
```

LangGraph fires events at every node transition and tool call. Langfuse captures all of them automatically — no manual span creation required.

**Open Prompt mode** — OpenAI wrapper (zero refactoring of existing call):

```python
from langfuse.openai import openai   # replaces: import openai

response = openai.chat.completions.create(
    model="gpt-4o",
    messages=[
        {"role": "system", "content": system_prompt},
        {"role": "user",   "content": user_message}
    ],
    metadata={"mode": "open_prompt", "session_id": session_id}
)
```

One import change. Everything else is identical to existing code.

---

## 5. Evaluation Service: Mode-Based Routing

Once a trace lands in Langfuse, the Evaluation Service fetches it and applies the correct rubric based on the `mode` tag.

### 5.1 Routing Logic

```python
def evaluate(trace):
    mode = trace.metadata.get("mode")

    if mode == "rag":
        return eval_rag(trace)           # existing logic, unchanged

    elif mode == "open_prompt":
        return eval_open_prompt(trace)   # new rubric — see 5.2

    elif mode == "agentic":
        return eval_agentic(trace)       # new rubric — see 5.3
```

### 5.2 Open Prompt Rubric

Since there is no source document or tool output, groundedness is explicitly not applicable. The rubric evaluates response quality on its own merits:

| Metric | Definition |
|---|---|
| **Relevance** | Does the response directly address the user's question? |
| **Coherence** | Is the response logically consistent and well-structured? |
| **Instruction Following** | Did the model respect constraints in the system prompt (tone, format, length)? |
| **Appropriate Confidence** | Did the model hedge where factual certainty was not possible? |
| **Groundedness** | Marked **N/A** — no source exists to ground against |

LLM-as-judge prompt template:

```
Evaluate this AI response. There is no document context — this is an open prompt response.

System prompt:  {system_prompt}
User message:   {user_message}
Response:       {response}

Score each dimension from 1–5:
1. Relevance           — does it answer what was asked?
2. Coherence           — is it logically structured and consistent?
3. Instruction following — did it respect the system prompt?
4. Appropriate confidence — did it hedge where it should?

Return JSON only: { relevance, coherence, instruction_following, confidence, reasoning }
```

### 5.3 Agentic Tool Rubric

For tool-based responses, groundedness is redefined as: *did the final answer faithfully use the tool outputs?* Tool outputs replace the document as the grounding source.

| Metric | Definition |
|---|---|
| **Query Formulation** | Were tool inputs (e.g. search queries) specific and well-targeted? |
| **Iteration Quality** | When the agent refined its query, did it improve? |
| **Tool Output Utilisation** | Did the final answer actually use what the tools returned? |
| **Groundedness** | Is the final answer supported by tool outputs (not hallucinated)? |
| **Redundancy** | Were any tool calls wasteful or duplicated? |
| **Answer Completeness** | Did the agent synthesise all relevant tool outputs? |

LLM-as-judge prompt template:

```
Evaluate this AI agent's response. The agent used tool calls to retrieve information.
Treat tool outputs as the grounding source.

User query:      {user_query}
Tool calls made:
  {for each step: tool_name, tool_input, tool_output}
Final answer:    {final_answer}

Score each dimension from 1–5:
1. Query formulation     — were tool inputs well-formed?
2. Tool utilisation      — did the answer use what was retrieved?
3. Groundedness          — is the answer supported by tool outputs?
4. Redundancy            — were any calls wasteful? (5 = no redundancy)
5. Completeness          — were all relevant results synthesised?

Return JSON only: { query_formulation, tool_utilisation, groundedness, redundancy, completeness, reasoning }
```

---

## 6. Failure Mode Flagging

In addition to LLM-as-judge scoring, the Evaluation Service will apply deterministic flags to agentic traces:

| Flag | Condition | Signal |
|---|---|---|
| `excessive_steps` | > 5 tool calls in one run | Agent struggling to find answer |
| `duplicate_query` | Same tool input used twice | Redundant search, possible loop |
| `empty_results` | All tool calls returned no results | Retrieval failure |
| `low_groundedness` | Groundedness score < 3 | Possible hallucinated synthesis |
| `no_tool_output_used` | Final answer shares no content with tool outputs | Answer fabricated |

These flags appear as tags on the Langfuse trace and are included in the evaluation payload returned to the Eval Service dashboard.

---

## 7. Evaluation Volume Strategy

Running LLM-as-judge on every call is expensive. The following sampling strategy is proposed:

| Mode | Online (Production) | Offline (Pre-deploy) |
|---|---|---|
| RAG | 100% (existing behaviour) | Golden dataset — 200 Q&A pairs |
| Open Prompt | 10–15% sampled | Golden dataset — 100 Q&A pairs |
| Agentic | 20% sampled (higher — more failure modes) | Golden dataset — 50 agent runs |

Offline evaluation runs as part of CI on every release candidate.

---

## 8. Options Considered

The following options were reviewed before landing on the approach above:

| Option | Description | Decision |
|---|---|---|
| **A — Skip entirely (N/A)** | Mark groundedness N/A for all non-RAG responses | ❌ Rejected — loses signal on agentic mode |
| **B — Different rubric per mode** | Apply mode-specific scoring dimensions | ✅ Adopted — see Section 5 |
| **C — Score as normal, flag mode** | Run existing rubric, tag with mode for filtering | ⚠️ Partial — used as transitional approach only |
| **D — Tool output as context** | Treat tool outputs as the grounding document | ✅ Adopted for agentic mode — see Section 5.3 |

---

## 9. Acceptance Criteria

- [ ] Research documented on this page and shared with Ethan Alberto and Alistair Boyer for review
- [ ] Internal alignment meeting held with data team and product team — decision signed off
- [ ] Langfuse self-hosted instance deployed in non-prod environment
- [ ] Instrumentation added to Chat Service for Open Prompt (OpenAI wrapper) and Agentic (LangGraph callback)
- [ ] Mode-based routing logic added to Evaluation Service
- [ ] Open Prompt rubric implemented and validated against 20 manual test cases
- [ ] Agentic rubric implemented and validated against 10 manual agent runs
- [ ] Evaluation Service behaviour for Open Prompt responses defined and documented
- [ ] Evaluation Service behaviour for Agentic Tool responses defined and documented
- [ ] Sampling strategy agreed with data team

---

## 10. Open Questions

| Question | Owner | Status |
|---|---|---|
| What sampling rate is acceptable for Open Prompt online eval? | Ethan Alberto | ❓ Open |
| Should sub-agent internal steps be passed to Eval Service or only the final tool output per sub-agent? | [Your Name] | ❓ Open |
| Do we need per-user trace isolation for data privacy? | Alistair Boyer | ❓ Open |
| Langfuse self-hosting: which environment team owns the deployment? | Platform Team | ❓ Open |

---

## 11. References

- [Langfuse Documentation](https://langfuse.com/docs)
- [Langfuse LangGraph Integration](https://langfuse.com/integrations/frameworks/langchain)
- [DeepEval Agent Evaluation Guide](https://deepeval.com/docs/getting-started-agents)
- LLMPS-6476 Jira Ticket
- Internal: Evaluation Service API Contract (link)
- Internal: Chat Service Architecture Diagram (link)
