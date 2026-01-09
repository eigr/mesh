defmodule Mesh.Shards.ShardConfig do
  def shard_count do
    Application.get_env(:mesh, :shards, 4096)
  end
end
