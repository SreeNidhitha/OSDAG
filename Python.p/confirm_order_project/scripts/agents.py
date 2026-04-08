
import os
from autogen_agentchat.agents import AssistantAgent, UserProxyAgent
from autogen_agentchat.messages import StructuredMessage
from autogen_agentchat.tools import AgentTool
from autogen_ext.models.azure import AzureAIChatCompletionClient
from .scheduler_tool import schedule_order

def build_agents():
    model_client = AzureAIChatCompletionClient(
        model=os.environ["AZURE_OPENAI_DEPLOYMENT"],
        api_key=os.environ["AZURE_OPENAI_API_KEY"],
        endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
        api_version=os.environ.get("AZURE_OPENAI_API_VERSION", "2025-01-01-preview"),
    )

    assistant = AssistantAgent(
        "delivery_scheduler_assistant",
        model_client=model_client,
        system_message="You are the Delivery Scheduler Agent. Call the 'schedule_order' tool to compute delivery schedule."
    )

    schedule_tool = AgentTool(
        name="schedule_order",
        description="Compute delivery schedule using ATP + preferences + data sources directory.",
        func=lambda atp_input, prefs_input, data_dir: schedule_order(atp_input, prefs_input, data_dir),
        parameters={
            "type": "object",
            "properties": {
                "atp_input": {"type": "object"},
                "prefs_input": {"type": "object"},
                "data_dir": {"type": "string"}
            },
            "required": ["atp_input", "prefs_input", "data_dir"]
        }
    )

    user_proxy = UserProxyAgent("user_proxy", human_input_mode="NEVER")
    user_proxy.register_tool(schedule_tool)
    return assistant, user_proxy

async def run_schedule(atp_payload: dict, prefs_payload: dict, data_dir: str):
    assistant, user_proxy = build_agents()
    task = StructuredMessage(content={
        "intent": "Schedule delivery",
        "inputs": {"atp_input": atp_payload, "prefs_input": prefs_payload, "data_dir": data_dir}
    })
    result = await assistant.run(task=task, teammates=[user_proxy])
    last = result.messages[-1]
    return last.content if hasattr(last, "content") else {"messages": [m.model_dump() for m in result.messages]}
