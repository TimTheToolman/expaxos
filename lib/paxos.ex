defmodule Paxos do
  
  def start(nodes) do
    Paxos.Application.start(nodes, 0)
  end

  def submit(value) do
    Paxos.Node.submit(value)
  end

end
