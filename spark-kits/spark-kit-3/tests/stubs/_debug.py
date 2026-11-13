import re
expr = '.nodes[] | select(.role == "worker") | "\\(.node_id)|\\(.lan_ip)|\\(.model_recipe)"'
m = re.match(r'^\.nodes\[\]\s*\|\s*select\(\.(\w+)\s*==\s*"([^"]+)"\)\s*\|\s*"(.*)"$', expr)
print("match:", bool(m))
if m:
    tmpl = m.group(3)
    print("tmpl:", repr(tmpl))
    node = {"node_id": "spark-02", "lan_ip": "10.0.0.31", "model_recipe": "other-model"}
    print("findall:", re.findall(r"\\\((\w+)\)", tmpl))
    print(re.sub(r"\\\((\w+)\)", lambda mm: str(node.get(mm.group(1), "")), tmpl))
