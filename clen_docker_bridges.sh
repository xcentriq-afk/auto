for net in $(docker network ls --filter driver=bridge --format '{{.Name}}'); do
  used=$(docker network inspect "$net" -f '{{json .Containers}}' | jq 'length')
  if [ "$used" -gt 0 ]; then
    echo "🟢 $net (w użyciu)"
  else
    echo "⚪ $net (NIEUŻYWANA)"
  fi
done

for net in $(docker network ls --filter driver=bridge --format '{{.Name}}'); do
  used=$(docker network inspect "$net" -f '{{json .Containers}}' | jq 'length')
  if [ "$used" -eq 0 ] && [ "$net" != "bridge" ]; then
    echo "Usuwam: $net"
    docker network rm "$net"
  fi
done

