# Explicação: Por que apenas 8 de 20 atores mudaram?

## 🔑 Conceitos Chave

### 1. Sistema de 2 Níveis
```
Actor ID → Shard (FIXO) → Node (MUDA com topologia)
```

### 2. Mapeamento Actor → Shard (NUNCA muda)
- Usa `phash2(actor_id, 4096)` 
- Cada ator **sempre** mapeia para o mesmo shard
- Exemplo: `"game_3"` → shard `48` (sempre!)

### 3. Mapeamento Shard → Node (MUDA quando nodes mudam)
- Usa `rem(shard, node_count)` (estratégia EventualConsistency)
- Quando número de nodes muda, **alguns** shards mudam de owner

## 📊 O que aconteceu no teste

### Antes (1 node com :game)
```
Nodes: [node1]
node_count = 1

Shard 48:  rem(48, 1) = 0  → nodes[0] = node1
Shard 57:  rem(57, 1) = 0  → nodes[0] = node1
Shard 294: rem(294, 1) = 0 → nodes[0] = node1
... todos os shards → node1
```

### Depois (2 nodes com :game)
```
Nodes: [node2, node1]  (sorted alphabetically!)
node_count = 2

Shard 48:  rem(48, 2) = 0  → nodes[0] = node2  ⚠️ MUDOU!
Shard 57:  rem(57, 2) = 1  → nodes[1] = node1  ✅ IGUAL
Shard 294: rem(294, 2) = 0 → nodes[0] = node2  ⚠️ MUDOU!
Shard 552: rem(552, 2) = 0 → nodes[0] = node2  ⚠️ MUDOU!
Shard 751: rem(751, 2) = 1 → nodes[1] = node1  ✅ IGUAL
...
```

## 🎯 Resultado

### Distribuição por Paridade do Shard
- **Shards pares** (rem = 0): vão para `node2` → **MUDARAM**
- **Shards ímpares** (rem = 1): vão para `node1` → **IGUAIS**

### Atores que Mudaram (8 atores)
```
game_3  (shard 48)   → par   → node2  ⚠️
game_6  (shard 3444) → par   → node2  ⚠️
game_9  (shard 2196) → par   → node2  ⚠️
game_11 (shard 2658) → par   → node2  ⚠️
game_12 (shard 3678) → par   → node2  ⚠️
game_13 (shard 294)  → par   → node2  ⚠️
game_14 (shard 552)  → par   → node2  ⚠️
game_15 (shard 2510) → par   → node2  ⚠️
```

### Atores que Ficaram (12 atores)
```
game_1  (shard 1467) → ímpar → node1  ✅
game_2  (shard 2343) → ímpar → node1  ✅
game_4  (shard 1561) → ímpar → node1  ✅
game_5  (shard 2817) → ímpar → node1  ✅
game_7  (shard 919)  → ímpar → node1  ✅
game_8  (shard 2889) → ímpar → node1  ✅
game_10 (shard 3357) → ímpar → node1  ✅
game_16 (shard 2365) → ímpar → node1  ✅
game_17 (shard 1157) → ímpar → node1  ✅
game_18 (shard 751)  → ímpar → node1  ✅
game_19 (shard 1613) → ímpar → node1  ✅
game_20 (shard 57)   → ímpar → node1  ✅
```

## ✅ Por que está CORRETO?

1. **Distribuição Baseada em Shards, Não em Atores**
   - Com 20 shards únicos e 2 nodes
   - Esperado: ~50% dos shards mudam
   - Real: 8 de 20 shards mudaram (40%)
   - Variação normal devido à distribuição aleatória de IDs

2. **Rebalancing Inteligente**
   - Identificou os 8 shards que mudaram de owner
   - Parou **apenas** os atores nesses shards
   - Manteve os 12 atores nos shards estáveis rodando

3. **Eficiência Máxima**
   - Sem rebalancing: 20 atores parados (100%)
   - Com rebalancing: 8 atores parados (40%)
   - **60% dos atores não foram interrompidos!** 🎉

## 🔬 Caso Especial: Por que 40% e não 50%?

O esperado seria ~50%, mas temos 40% porque:
- A distribuição de hashes é pseudo-aleatória
- Com apenas 20 amostras, variações são normais
- Se testarmos com 1000 atores, chegaríamos perto de 50/50

## 📝 Conclusão

**O comportamento está 100% correto!**

O rebalancing coordenado:
1. ✅ Calcula ownership antes e depois
2. ✅ Identifica shards que mudaram (8 de 20)
3. ✅ Para apenas atores nos shards afetados
4. ✅ Mantém atores em shards estáveis rodando
5. ✅ Minimiza disrupção durante mudanças de topologia

Isso é exatamente o que queríamos alcançar! 🚀
