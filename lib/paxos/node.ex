defmodule Paxos.Node do
  @moduledoc """
    Paxos.Node tracks the status of a node and accepts messages
    The states can be:
      leader
      candidate
      follower
      stragler
    Features:
      Master Leases
  """
  use GenFSM.Behaviour

  alias Paxos.Messages.PrepareReq, as: PrepareReq
  alias Paxos.Messages.PrepareResp, as: PrepareResp
  alias Paxos.Messages.AcceptReq, as: AcceptReq
  alias Paxos.Messages.AcceptResp, as: AcceptResp
  alias Paxos.Messages.LearnReq, as: LearnReq
  alias Paxos.Messages.SubmitReq, as: SubmitReq


  defrecord Instance, acceptor: nil, proposer: nil, learner: nil 

  defrecord State, instance: nil, actors: Instance.new(), 
                   lease_num: 0, lease_time: 0, nodes: [],
                   leader: nil, queue: Paxos.Queue.new(), 
                   self: nil, rand_time: 0 do
    def spawn_instance(value, leader, state) do
      {:ok, acc} =  Paxos.Acceptor.start_link(state.instance)
      {:ok, pro} =  Paxos.Proposer.start_link(state.instance, value, 
                    leader, state.nodes)
      {:ok, lrn} =  Paxos.Learner.start_link(state.instance)
      state.update(actors: Instance.new(acceptor: acc, proposer: pro, learner: lrn))
    end    
    def spawn_instance(state) do
      {:ok, acc} =  Paxos.Acceptor.start_link(state.instance)
      {:ok, lrn} =  Paxos.Learner.start_link(state.instance)
      state.update(actors: Instance.new(acceptor: acc, learner: lrn))
    end
    def spawn_proposer(value, leader, state) do
      {:ok, pro} =  Paxos.Proposer.start_link(state.instance, value,
                    leader, state.nodes)
      state.update(actors: state.actors.update(proposer: pro)) 
    end
    def queue_empty(state) do
      Paxos.Queue.is_empty(state.queue)
    end
    def queue_insert(item, state) do
      queue = Paxos.Queue.insert(state.queue, item)
      state.update(queue: queue)
    end
    def queue_take(state) do
      Paxos.Queue.take(state.queue)
    end
  end

  def start_link(nodes, instance) do
    :gen_fsm.start_link({:local, __MODULE__}, __MODULE__, [nodes, instance], [])
  end
  
  def send(node, message) do
    :gen_fsm.send_all_state_event(__MODULE__, {:send, node, message})
  end

  def broadcast(message) do
    :gen_fsm.send_all_state_event(__MODULE__, {:broadcast, message})
  end

  def submit(value) do
    :gen_fsm.send_all_state_event(__MODULE__, {:submit, value})
  end

  def log(value) do
    :gen_fsm.sync_send_all_state_event(__MODULE__, {:log, value})
  end

  def learn(value) do
    :gen_fsm.send_all_state_event(__MODULE__, {:learn, value})
  end
  
  def get_status() do
    :gen_fsm.sync_send_all_state_event(__MODULE__, :get_status)
  end

  def init([nodes, instance]) do
    {a,b,c} = :erlang.now
    :random.seed(a, b, c)
    rand = :random.uniform(10000)
    IO.puts(rand)
    state = State.new(instance: instance, nodes: nodes, lease_time: 10000, rand_time: rand, self: Node.self)
    state = state.spawn_instance     
    {:ok, :candidate, state}
  end

  def handle_sync_event({:log, value}, _from, state_name, state) do
    Paxos.Logger.log(value, state.instance)
    state = state.update(instance: state.instance + 1)
    if state_name == :leader and state.queue_empty !== true do
      {:value, value, queue} = state.queue_take
      state = state.update(queue: queue)
      state = state.spawn_instance(value, true)
    else
      state = state.spawn_instance
    end
    {:reply, :ok, state_name, state}
  end

  def handle_sync_event(:get_status, _from, state_name, state) do
    {:reply, state_name, state_name, state}
  end
  def handle_event({:send, node, message}, state_name, state) do
    IO.puts("sending")
    {__MODULE__, node} <- {:message, message}
    {:next_state, state_name, state}
  end

  def handle_event({:submit, value}, state_name, state) 
  when state_name == :leader or state_name == :candidate do
    if state.queue_empty do
      state = state.queue_insert(value)
      is_leader = state_name == :leader 
      state = state.spawn_proposer(value, is_leader)
    else
      state = state.queue_insert(value)
    end
    {:next_state, state_name, state}
  end

  def handle_event({:submit,value}, state_name, state) do
    message = SubmitReq.new(instance: state.instance, nodeid: state.self, value: value)
    handle_event({:send, state.leader, message}, state_name, state)
  end

  def handle_event({:broadcast, message}, state_name, state) do
    Enum.each(state.nodes, fn(node) ->
      {__MODULE__, node} <- {:message, message}
    end)
    {:next_state, state_name, state}
  end

  def handle_event(:set_lease_timer, state_name, state) do
    state = state.update(lease_num: state.lease_num + 1)
    case state_name do
      :leader ->
        #shorter lease for leader so he can renew
        time = state.lease_time - (state.lease_time / 4)
        lease(time, state.lease_num)
        {:next_state, state_name, state}
      _ ->
        lease(state.lease_time, state.lease_num)
        {:next_state, state_name, state}
    end
  end

  @doc """
    Distinguished learner
  """
  def handle_event({:learn, value}, state_name, state) do
    Paxos.Learner.learn(state.actors.learner, value) 
    {:next_state, state_name, state}
  end

  @doc """
    Accept Requests
  """
 ### def handle_info({:message, message=AcceptReq[nodeid: from, instance: minstance]}, :follower, state=State[leader: leader, instance: instance]) when (from == leader or leader == nil) and minstance == instance do
    ###Paxos.Acceptor.message(state.actors.acceptor, message)
    ###{:next_state, :follower, state}
  ###end

  def handle_info({:message, message=AcceptReq[nodeid: from, instance: minstance]}, :follower, state=State[leader: leader, instance: instance]) when from == leader and minstance > instance do
    #kick off catchup
    {:next_state, :stagler, state}
  end
 
  def handle_info({:message, message=AcceptReq[nodeid: from, instance: minstance]}, state_name, state=State[instance: instance, self: self]) when minstance == instance do
    Paxos.Acceptor.message(state.actors.acceptor, message)
    {:next_state, state_name, state}
  end

  @doc """
    Prepare Requests
  """

  def handle_info({:message, message=PrepareReq[instance: minstance, nodeid: from]}, state_name, state=State[instance: instance, leader: leader]) when minstance == instance and (leader == nil or leader == from) do
    Paxos.Acceptor.message(state.actors.acceptor, message)
    {:next_state, state_name, state}
  end

  def handle_info({:message, message=PrepareResp[instance: minstance]}, state_name, state=State[instance: instance]) when minstance == instance do
    Paxos.Proposer.message(state.actors.proposer, message)
    {:next_state, state_name, state}
  end

  def handle_info({:message, message=AcceptResp[instance: minstance]}, state_name, state=State[instance: instance]) when minstance == instance do
    Paxos.Proposer.message(state.actors.proposer, message)
    {:next_state, state_name, state}
  end
 
  def handle_info({:message, message=LearnReq[instance: minstance, nodeid: from]}, state_name, state=State[instance: instance, self: id]) when minstance == instance and from !== id do
    IO.puts("learn req")
    Paxos.Learner.message(state.actors.learner, message)    
    time = state.lease_time + state.rand_time
    rand = :random.uniform(10000)
    state = state.update(lease_num: state.lease_num + 1, rand_time: rand, leader: from)
    lease(time, state.lease_num)
    {:next_state, :follower, state}
  end

  
  def handle_info({:message, message=LearnReq[instance: minstance, nodeid: from]}, state_name, state=State[instance: instance, self: id]) when minstance == instance and from == id do
    IO.puts(inspect(from))
    IO.puts(inspect(id))
    Paxos.Learner.message(state.actors.learner, message)    
    state = state.update(lease_num: state.lease_num + 1)
    lease(state.lease_time, state.lease_num)
    state = state.update(leader: Node.self())
    {:next_state, :leader, state}
  end


  def handle_info({:message, message=SubmitReq[]}, state_name, state) do
    #tell node if your no longer leader?
    handle_event({:submit,message.value}, state_name, state)
  end
 
  def handle_info({:lease_up, lease_num}, :leader, state=State[lease_num: current]) when current == lease_num do
    #send heartbeat paxos instance  
    handle_event({:submit, :heartbeat}, :leader, state)
  end

  def handle_info({:lease_up, lease_num}, :follower, state=State[lease_num: current]) when current == lease_num do
    #upgrade to candidate
    {:next_state, :candidate, state.update(leader: nil)}
  end

  def handle_info(message, state_name, state) do
    IO.puts(inspect(message))
    {:next_state, state_name, state}
  end

  defp lease(time, lease_num) do
    :erlang.send_after(time, Process.self(), {:lease_up, lease_num})
  end

end
