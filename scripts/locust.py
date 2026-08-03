import sys, os
import random

from locust import HttpUser, between, task
sys.path.insert(0, os.path.dirname(__file__))
from prompt import PROMPTS


API_KEY = os.getenv("API_KEY", "")
MODEL = os.getenv(
    "MODEL",
    "llama3"
)


class VLLMUser(HttpUser):
    # Simulate a user pausing between requests.
    wait_time = between(0.5, 2.0)

    @task
    def chat_completion(self):
        prompt = random.choice(PROMPTS)

        headers = {
            "Content-Type": "application/json",
        }

        if API_KEY:
            headers["Authorization"] = f"Bearer {API_KEY}"

        payload = {
            "model": MODEL,
            "messages": [
                {
                    "role": "system",
                    "content": "You are a technically precise assistant.",
                },
                {
                    "role": "user",
                    "content": prompt,
                },
            ],
            "temperature": 0.7,
            "max_tokens": 256,
            "stream": False,
        }

        with self.client.post(
            "/v1/chat/completions",
            json=payload,
            headers=headers,
            name="/v1/chat/completions",
            timeout=180,
            catch_response=True,
        ) as response:
            if response.status_code != 200:
                response.failure(
                    f"HTTP {response.status_code}: "
                    f"{response.text[:300]}"
                )
                return

            try:
                body = response.json()
            except ValueError:
                response.failure("Response was not valid JSON")
                return

            if not body.get("choices"):
                response.failure("Response did not contain choices")
                return

            response.success()





