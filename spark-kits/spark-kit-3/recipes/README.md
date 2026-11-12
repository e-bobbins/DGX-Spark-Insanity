# Model Recipes

Each file in this directory defines how to serve a specific model. Recipes are referenced by name in the inventory.yaml file.

## Recipe Format

```yaml
# recipe_name.yaml
hf_model_name: "nvidia/Qwen3.6-35B-A3B-NVFP4"  # HuggingFace model identifier
served_model_name: "qwen3.6-35b-a3b-nvfp4"     # Name exposed via LiteLLM
tool_call_parser: "qwen3_xml"                  # Tool call parser for vLLM
reasoning_parser: "qwen3"                      # Reasoning parser for vLLM
max_model_len: 262144                          # Maximum model length
gpu_memory_utilization: 0.8                    # GPU memory utilization (0.0-1.0)
max_num_seqs: 15                               # Maximum number of sequences
enable_auto_tool_choice: true                 # Enable auto tool choice
trust_remote_code: true                       # Trust remote code
```

## Adding a New Model

1. Create a new `.yaml` file in this directory (e.g., `qwen3.8-flash-next.yaml`)
2. Define the recipe parameters
3. Update inventory.yaml to reference the new recipe
4. Run the deploy script

## Default Recipe

The `qwen3.6-35b-a3b-nvfp4.yaml` recipe is the default and matches the spec requirement for `nvidia/Qwen3.6-35B-A3B-NVFP4`.

## Tune Parameters for 128GB Unified Memory

The default GPU memory utilization is set to 0.8 (80%) for the Grace-Blackwell GB10's 128GB unified memory, providing optimal performance for agentic workloads while maintaining headroom for system operations.
