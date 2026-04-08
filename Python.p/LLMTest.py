from openai import AzureOpenAI

openaiclient = AzureOpenAI(
api_key = "CjD1Yjq4drPVDyMTQAaY7W1VXP81jBuFcqpg5kHS6SdFzTsHaDhuJQQJ99BKACHYHv6XJ3w3AAABACOGQH5v",
api_version = "2025-01-01-preview",
azure_endpoint ="https://schoolofagenticaitraining.openai.azure.com/"
)

messages = [
    {
        "role": "system",
        "content": [
            {
                "type": "text",
                "text": "You are an AI assistant that helps people find information."
            }
        ]
    },
    {
        "role": "user",
        "content": [
            {
                "type": "text",
                "text": "hello"
            }
        ]
    }
]
response = openaiclient.chat.completions.create(
    model="gpt-4o",
    messages=messages,
    temperature = 0.3,
    max_tokens=4000,
    top_p=0.95,
    frequency_penalty=0,
    presence_penalty=0,
    stop=None,
    stream=False)

generated_llm_response = response.choices[0].message.content.strip()   
print("LLM Response after LT -----",generated_llm_response) 



