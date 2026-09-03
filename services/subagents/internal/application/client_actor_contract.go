package application

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const DurableClientActorContractSchemaV1 = 1

var (
	ErrClientActorInvalidBoundary      = errors.New("client actor boundary is invalid")
	ErrClientActorInvalidIdentifier    = errors.New("client actor durable identifier is invalid")
	ErrClientActorInvalidSemantic      = errors.New("client actor semantic family is invalid")
	ErrClientActorDuplicateWork        = errors.New("client actor work id already exists")
	ErrClientActorIdempotencyConflict  = errors.New("client actor idempotency key conflicts with prior payload digest")
	ErrClientActorDuplicateSemantic    = errors.New("client actor semantic family is not interchangeable")
	ErrClientActorPrivacyCanary        = errors.New("client actor durable payload contains forbidden private material")
	ErrClientActorStaleFence           = errors.New("client actor executor fence is stale")
	ErrClientActorUnknownWork          = errors.New("client actor work item is unknown")
	ErrClientActorUnassignedWork       = errors.New("client actor work is not assigned to this executor lease")
	ErrClientActorLeaseConflict        = errors.New("client actor work lease assignment conflicts with prior assignment")
	ErrClientActorAlreadySettled       = errors.New("client actor work is already terminally settled")
	ErrClientActorSettlementConflict   = errors.New("client actor settlement conflicts with prior durable settlement")
	ErrClientActorPresentationAckOnly  = errors.New("client actor presentation ack is projection-only")
	ErrClientActorPresentationAckRange = errors.New("client actor presentation ack is not pending and contiguous")
	ErrClientActorPresentationSource   = errors.New("client actor presentation source is not eligible")
	ErrClientActorContinuationSource   = errors.New("client actor self-continuation source is not eligible")
	ErrClientActorCorruptState         = errors.New("client actor durable state is corrupt")
)

type ClientActorSemanticFamily string

const (
	ClientActorSemanticTell             ClientActorSemanticFamily = "tell"
	ClientActorSemanticAsk              ClientActorSemanticFamily = "ask"
	ClientActorSemanticUserTurn         ClientActorSemanticFamily = "user_turn"
	ClientActorSemanticSelfContinuation ClientActorSemanticFamily = "self_continuation"
	ClientActorSemanticWaiting          ClientActorSemanticFamily = "waiting"
	ClientActorSemanticBlocked          ClientActorSemanticFamily = "blocked"
	ClientActorSemanticCompletion       ClientActorSemanticFamily = "completion"
	ClientActorSemanticPresentationAck  ClientActorSemanticFamily = "presentation_ack"
	ClientActorSemanticIntrospection    ClientActorSemanticFamily = "introspection"
)

type ClientActorExecutorFence struct {
	ActorEpoch         uint64 `json:"actor_epoch"`
	ExecutorGeneration uint64 `json:"executor_generation"`
	LeaseID            string `json:"lease_id"`
}

type DurableClientActorContent struct {
	Digest   [32]byte `json:"digest"`
	Size     int      `json:"size"`
	Redacted bool     `json:"redacted"`
	Ref      string   `json:"ref,omitempty"`
}

type ClientActorLogEntryKind string

const (
	ClientActorLogEntryKindWork       ClientActorLogEntryKind = "work"
	ClientActorLogEntryKindSettlement ClientActorLogEntryKind = "settlement"
)

type DurableClientActorLogEntry struct {
	EntryKind      ClientActorLogEntryKind   `json:"entry_kind"`
	ReplaySequence uint64                    `json:"replay_sequence"`
	Sequence       uint64                    `json:"sequence"`
	Family         ClientActorSemanticFamily `json:"family"`
	WorkID         string                    `json:"work_id"`
	ThreadID       string                    `json:"thread_id,omitempty"`
	Nonce          string                    `json:"nonce,omitempty"`
	Content        DurableClientActorContent `json:"content"`
	SourceWorkID   string                    `json:"source_work_id,omitempty"`
}

type DurableClientActorSettlement struct {
	WorkID             string                    `json:"work_id"`
	ThreadID           string                    `json:"thread_id"`
	Family             ClientActorSemanticFamily `json:"family"`
	WorkSequence       uint64                    `json:"work_sequence"`
	SettlementSequence uint64                    `json:"settlement_sequence"`
	EvidenceDigest     [32]byte                  `json:"evidence_digest"`
	Terminal           bool                      `json:"terminal"`
	SettlementHigh     uint64                    `json:"settlement_high"`
	ReplayEligible     bool                      `json:"replay_eligible"`
}

type DurableClientActorNonceRecord struct {
	WorkID string   `json:"work_id"`
	Digest [32]byte `json:"digest"`
}

type DurableClientActorContinuationRecord struct {
	WorkID string   `json:"work_id"`
	Digest [32]byte `json:"digest"`
}

type DurableClientActorLeaseAssignment struct {
	Fence    ClientActorExecutorFence `json:"fence"`
	ThreadID string                   `json:"thread_id"`
}

type DurableClientActorPresentationTuple struct {
	ActorID  string                   `json:"actor_id"`
	Fence    ClientActorExecutorFence `json:"fence"`
	Sequence uint64                   `json:"sequence"`
	Order    uint64                   `json:"order"`
}

type DurableClientActorContinuationPolicy struct {
	BudgetRemaining int       `json:"budget_remaining"`
	Deadline        time.Time `json:"deadline"`
}

type DurableClientActorContractState struct {
	SchemaVersion            int                                             `json:"schema_version"`
	ActorID                  string                                          `json:"actor_id"`
	NextSequence             uint64                                          `json:"next_sequence"`
	NextReplaySequence       uint64                                          `json:"next_replay_sequence"`
	CurrentFence             ClientActorExecutorFence                        `json:"current_fence"`
	Log                      []DurableClientActorLogEntry                    `json:"log"`
	UserTurnByNonce          map[string]DurableClientActorNonceRecord        `json:"user_turn_by_nonce"`
	WorkFamilies             map[string]ClientActorSemanticFamily            `json:"work_families"`
	WorkSequences            map[string]uint64                               `json:"work_sequences"`
	WorkBySequence           map[uint64]string                               `json:"work_by_sequence"`
	WorkThreads              map[string]string                               `json:"work_threads"`
	WorkLeases               map[string]DurableClientActorLeaseAssignment    `json:"work_leases"`
	Settlements              map[string]DurableClientActorSettlement         `json:"settlements"`
	SettlementHighWater      uint64                                          `json:"settlement_high_water"`
	Introspected             map[string]uint64                               `json:"introspected"`
	IntrospectionSources     map[string]string                               `json:"introspection_sources"`
	PendingPresentation      map[uint64]DurableClientActorPresentationTuple  `json:"pending_presentation"`
	NextPresentationOrder    uint64                                          `json:"next_presentation_order"`
	PresentationAckHigh      uint64                                          `json:"presentation_ack_high"`
	PresentationAckOrderHigh uint64                                          `json:"presentation_ack_order_high"`
	ContinuationKeys         map[string]DurableClientActorContinuationRecord `json:"continuation_keys"`
	ContinuationPolicy       DurableClientActorContinuationPolicy            `json:"continuation_policy"`
}

func NewDurableClientActorContractState(actorID string, fence ClientActorExecutorFence) (DurableClientActorContractState, error) {
	if err := validateClientActorDurableID(actorID); err != nil {
		return DurableClientActorContractState{}, err
	}
	if !validClientActorFence(fence) {
		return DurableClientActorContractState{}, ErrClientActorInvalidBoundary
	}
	state := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: actorID, NextSequence: 1, NextReplaySequence: 1, NextPresentationOrder: 1, CurrentFence: fence, ContinuationPolicy: DurableClientActorContinuationPolicy{BudgetRemaining: 3, Deadline: time.Now().Add(time.Hour)}}
	state.ensureMaps()
	return state, nil
}

func (s *DurableClientActorContractState) AdmitUserTurn(nonce string, payload []byte) (DurableClientActorLogEntry, bool, error) {
	return s.AdmitUserTurnForThread(s.CurrentFence, "default", nonce, payload)
}

func (s *DurableClientActorContractState) AdmitUserTurnForThread(fence ClientActorExecutorFence, threadID, nonce string, payload []byte) (DurableClientActorLogEntry, bool, error) {
	if err := s.ensureReady(); err != nil {
		return DurableClientActorLogEntry{}, false, err
	}
	if !sameClientActorFence(fence, s.CurrentFence) {
		return DurableClientActorLogEntry{}, false, ErrClientActorInvalidBoundary
	}
	if err := validateClientActorDurableID(threadID); err != nil {
		return DurableClientActorLogEntry{}, false, err
	}
	if err := validateClientActorDurableID(nonce); err != nil {
		return DurableClientActorLogEntry{}, false, err
	}
	if err := rejectClientActorPrivateMaterial(payload); err != nil {
		return DurableClientActorLogEntry{}, false, err
	}
	digest := sha256.Sum256(payload)
	if record, ok := s.UserTurnByNonce[nonce]; ok {
		if record.Digest != digest {
			return DurableClientActorLogEntry{}, false, ErrClientActorIdempotencyConflict
		}
		entry, err := s.logEntry(record.WorkID)
		return entry, false, err
	}
	workID := fmt.Sprintf("user-turn:%s:%d", s.ActorID, s.NextSequence)
	entry, err := s.append(ClientActorSemanticUserTurn, workID, threadID, nonce, payload)
	if err != nil {
		return DurableClientActorLogEntry{}, false, err
	}
	s.UserTurnByNonce[nonce] = DurableClientActorNonceRecord{WorkID: workID, Digest: digest}
	return entry, true, nil
}

func (s *DurableClientActorContractState) AppendWork(family ClientActorSemanticFamily, workID string, payload []byte) (DurableClientActorLogEntry, error) {
	return s.AppendWorkForThread(family, workID, "default", payload)
}

func (s *DurableClientActorContractState) AppendWorkForThread(family ClientActorSemanticFamily, workID, threadID string, payload []byte) (DurableClientActorLogEntry, error) {
	if family == ClientActorSemanticPresentationAck {
		return DurableClientActorLogEntry{}, ErrClientActorPresentationAckOnly
	}
	if family == ClientActorSemanticUserTurn || family == ClientActorSemanticSelfContinuation {
		return DurableClientActorLogEntry{}, ErrClientActorInvalidSemantic
	}
	return s.append(family, workID, threadID, "", payload)
}

func (s *DurableClientActorContractState) ClientOriginAppendWork(_ ClientActorExecutorFence, _ ClientActorSemanticFamily, _ string, _ []byte) (DurableClientActorLogEntry, error) {
	return DurableClientActorLogEntry{}, ErrClientActorInvalidBoundary
}

func (s *DurableClientActorContractState) ClientOriginEnqueueSelfContinuation(_ ClientActorExecutorFence, _ string, _ uint64, _ uint32, _ []byte) (DurableClientActorLogEntry, bool, error) {
	return DurableClientActorLogEntry{}, false, ErrClientActorInvalidBoundary
}

func (s *DurableClientActorContractState) AssignWorkToLease(workID string, fence ClientActorExecutorFence) error {
	if err := s.ensureReady(); err != nil {
		return err
	}
	threadID, ok := s.WorkThreads[workID]
	if !ok {
		return ErrClientActorUnknownWork
	}
	if !sameClientActorFence(fence, s.CurrentFence) {
		return ErrClientActorStaleFence
	}
	if settlement, ok := s.Settlements[workID]; ok && settlement.Terminal {
		return ErrClientActorAlreadySettled
	}
	assignment := DurableClientActorLeaseAssignment{Fence: fence, ThreadID: threadID}
	if existing, ok := s.WorkLeases[workID]; ok {
		if existing == assignment {
			return nil
		}
		return ErrClientActorLeaseConflict
	}
	s.WorkLeases[workID] = assignment
	return nil
}

func (s *DurableClientActorContractState) SettleWork(fence ClientActorExecutorFence, workID string, family ClientActorSemanticFamily, terminal bool, encodedPayload []byte, parse func([]byte) ([32]byte, error)) (DurableClientActorSettlement, bool, error) {
	if err := s.ensureReady(); err != nil {
		return DurableClientActorSettlement{}, false, err
	}
	if !sameClientActorFence(fence, s.CurrentFence) {
		return DurableClientActorSettlement{}, false, ErrClientActorStaleFence
	}
	assignment, ok := s.WorkLeases[workID]
	if !ok || !sameClientActorFence(assignment.Fence, fence) {
		return DurableClientActorSettlement{}, false, ErrClientActorUnassignedWork
	}
	storedFamily, ok := s.WorkFamilies[workID]
	if !ok {
		return DurableClientActorSettlement{}, false, ErrClientActorUnknownWork
	}
	if storedFamily != family {
		return DurableClientActorSettlement{}, false, ErrClientActorDuplicateSemantic
	}
	if err := rejectClientActorPrivateMaterial(encodedPayload); err != nil {
		return DurableClientActorSettlement{}, false, err
	}
	if existing, ok := s.Settlements[workID]; ok {
		digest, err := parse(encodedPayload)
		if err != nil {
			return DurableClientActorSettlement{}, false, err
		}
		if existing.Family != family {
			return DurableClientActorSettlement{}, false, ErrClientActorDuplicateSemantic
		}
		if existing.EvidenceDigest != digest || existing.Terminal != terminal {
			return DurableClientActorSettlement{}, false, ErrClientActorSettlementConflict
		}
		return existing, false, nil
	}
	digest, err := parse(encodedPayload)
	if err != nil {
		return DurableClientActorSettlement{}, false, err
	}
	replaySequence := s.nextReplayLogSequence()
	settlement := DurableClientActorSettlement{WorkID: workID, ThreadID: assignment.ThreadID, Family: family, WorkSequence: s.WorkSequences[workID], SettlementSequence: replaySequence, EvidenceDigest: digest, Terminal: terminal, ReplayEligible: !terminal}
	settlement.SettlementHigh = s.contiguousSettlementHighWaterWith(workID)
	s.Settlements[workID] = settlement
	s.SettlementHighWater = settlement.SettlementHigh
	s.appendSettlementReplayEntry(settlement)
	return settlement, true, nil
}

func (s *DurableClientActorContractState) AppendIntrospectionForSource(sourceTurnID, workID string, payload []byte) (DurableClientActorLogEntry, error) {
	if err := s.ensureReady(); err != nil {
		return DurableClientActorLogEntry{}, err
	}
	threadID, ok := s.WorkThreads[sourceTurnID]
	if !ok {
		return DurableClientActorLogEntry{}, ErrClientActorContinuationSource
	}
	return s.AppendIntrospectionForThread(sourceTurnID, workID, threadID, payload)
}

func (s *DurableClientActorContractState) AppendIntrospectionForThread(sourceTurnID, workID, threadID string, payload []byte) (DurableClientActorLogEntry, error) {
	if err := validateClientActorDurableID(sourceTurnID); err != nil {
		return DurableClientActorLogEntry{}, err
	}
	if _, ok := s.WorkFamilies[sourceTurnID]; !ok {
		return DurableClientActorLogEntry{}, ErrClientActorContinuationSource
	}
	entry, err := s.append(ClientActorSemanticIntrospection, workID, threadID, "", payload)
	if err != nil {
		return DurableClientActorLogEntry{}, err
	}
	s.IntrospectionSources[workID] = sourceTurnID
	return entry, nil
}

func (s *DurableClientActorContractState) MarkIntrospected(sourceTurnID string, introspectionSequence uint64) error {
	if err := s.ensureReady(); err != nil {
		return err
	}
	settlement, ok := s.Settlements[sourceTurnID]
	if !ok || settlement.Terminal || !settlement.ReplayEligible {
		return ErrClientActorContinuationSource
	}
	introWorkID, ok := s.WorkBySequence[introspectionSequence]
	if !ok || s.WorkFamilies[introWorkID] != ClientActorSemanticIntrospection || s.IntrospectionSources[introWorkID] != sourceTurnID {
		return ErrClientActorContinuationSource
	}
	introSettlement, ok := s.Settlements[introWorkID]
	if !ok || !introSettlement.Terminal || introSettlement.ReplayEligible || introSettlement.ThreadID != s.WorkThreads[sourceTurnID] {
		return ErrClientActorContinuationSource
	}
	s.Introspected[sourceTurnID] = introspectionSequence
	return nil
}

func (s *DurableClientActorContractState) DeterministicContinuationKey(sourceTurnID string, introspectionSequence uint64, continuationIndex uint32) string {
	material := fmt.Sprintf("%s\x00%s\x00%d\x00%d", s.ActorID, sourceTurnID, introspectionSequence, continuationIndex)
	sum := sha256.Sum256([]byte(material))
	return "self-continuation:" + hex.EncodeToString(sum[:])
}

func (s *DurableClientActorContractState) EnqueueSelfContinuation(sourceTurnID string, introspectionSequence uint64, continuationIndex uint32, payload []byte) (DurableClientActorLogEntry, bool, error) {
	return s.EnqueueSelfContinuationForThread(sourceTurnID, s.WorkThreads[sourceTurnID], introspectionSequence, continuationIndex, payload)
}

func (s *DurableClientActorContractState) EnqueueSelfContinuationForThread(sourceTurnID, threadID string, introspectionSequence uint64, continuationIndex uint32, payload []byte) (DurableClientActorLogEntry, bool, error) {
	if err := s.ensureReady(); err != nil {
		return DurableClientActorLogEntry{}, false, err
	}
	if err := rejectClientActorPrivateMaterial(payload); err != nil {
		return DurableClientActorLogEntry{}, false, err
	}
	if threadID == "" || s.WorkThreads[sourceTurnID] != threadID || s.Introspected[sourceTurnID] != introspectionSequence || s.ContinuationPolicy.BudgetRemaining <= 0 || time.Now().After(s.ContinuationPolicy.Deadline) {
		return DurableClientActorLogEntry{}, false, ErrClientActorContinuationSource
	}
	key := s.DeterministicContinuationKey(sourceTurnID, introspectionSequence, continuationIndex)
	digest := sha256.Sum256(payload)
	if record, ok := s.ContinuationKeys[key]; ok {
		if record.Digest != digest {
			return DurableClientActorLogEntry{}, false, ErrClientActorIdempotencyConflict
		}
		entry, err := s.logEntry(record.WorkID)
		return entry, false, err
	}
	entry, err := s.append(ClientActorSemanticSelfContinuation, key, threadID, "", payload)
	if err != nil {
		return DurableClientActorLogEntry{}, false, err
	}
	s.ContinuationKeys[key] = DurableClientActorContinuationRecord{WorkID: key, Digest: digest}
	s.ContinuationPolicy.BudgetRemaining--
	return entry, true, nil
}

func (s *DurableClientActorContractState) EmitPresentation(sequence uint64) error {
	if err := s.ensureReady(); err != nil {
		return err
	}
	workID, ok := s.WorkBySequence[sequence]
	if sequence == 0 || sequence >= s.NextSequence || !ok {
		return ErrClientActorPresentationAckRange
	}
	settlement, settled := s.Settlements[workID]
	if s.WorkFamilies[workID] != ClientActorSemanticCompletion || !settled || !settlement.Terminal {
		return ErrClientActorPresentationSource
	}
	if s.NextPresentationOrder == 0 {
		s.NextPresentationOrder = 1
	}
	if _, exists := s.PendingPresentation[sequence]; exists {
		return nil
	}
	s.PendingPresentation[sequence] = DurableClientActorPresentationTuple{ActorID: s.ActorID, Fence: s.CurrentFence, Sequence: sequence, Order: s.NextPresentationOrder}
	s.NextPresentationOrder++
	return nil
}

func (s *DurableClientActorContractState) AckPresentation(actorID string, fence ClientActorExecutorFence, sequence uint64) error {
	if err := s.ensureReady(); err != nil {
		return err
	}
	pending, ok := s.PendingPresentation[sequence]
	if !ok || pending.Order != s.PresentationAckOrderHigh+1 {
		return ErrClientActorPresentationAckRange
	}
	if actorID != pending.ActorID || !sameClientActorFence(fence, pending.Fence) {
		return ErrClientActorStaleFence
	}
	delete(s.PendingPresentation, sequence)
	if sequence > s.PresentationAckHigh {
		s.PresentationAckHigh = sequence
	}
	s.PresentationAckOrderHigh = pending.Order
	return nil
}

func (s *DurableClientActorContractState) append(family ClientActorSemanticFamily, workID, threadID, nonce string, payload []byte) (DurableClientActorLogEntry, error) {
	if err := s.ensureReady(); err != nil {
		return DurableClientActorLogEntry{}, err
	}
	if err := validateClientActorDurableID(workID); err != nil {
		return DurableClientActorLogEntry{}, err
	}
	if err := validateClientActorDurableID(threadID); err != nil {
		return DurableClientActorLogEntry{}, err
	}
	if !validClientActorFamily(family) {
		return DurableClientActorLogEntry{}, ErrClientActorInvalidSemantic
	}
	if existing, exists := s.WorkFamilies[workID]; exists {
		if existing == family && s.logEntryDigest(workID) == sha256.Sum256(payload) {
			return DurableClientActorLogEntry{}, ErrClientActorDuplicateWork
		}
		return DurableClientActorLogEntry{}, ErrClientActorDuplicateWork
	}
	if err := rejectClientActorPrivateMaterial(payload); err != nil {
		return DurableClientActorLogEntry{}, err
	}
	entry := DurableClientActorLogEntry{EntryKind: ClientActorLogEntryKindWork, ReplaySequence: s.nextReplayLogSequence(), Sequence: s.nextWorkSequence(), Family: family, WorkID: workID, ThreadID: threadID, Nonce: nonce, Content: durableClientActorContent(payload)}
	s.Log = append(s.Log, entry)
	s.WorkFamilies[workID] = family
	s.WorkSequences[workID] = entry.Sequence
	s.WorkBySequence[entry.Sequence] = workID
	s.WorkThreads[workID] = threadID
	return entry, nil
}

func (s *DurableClientActorContractState) appendSettlementReplayEntry(settlement DurableClientActorSettlement) {
	s.Log = append(s.Log, DurableClientActorLogEntry{EntryKind: ClientActorLogEntryKindSettlement, ReplaySequence: settlement.SettlementSequence, Family: settlement.Family, WorkID: "settlement:" + settlement.WorkID, ThreadID: settlement.ThreadID, Content: DurableClientActorContent{Digest: settlement.EvidenceDigest, Redacted: true}, SourceWorkID: settlement.WorkID})
}

func (s DurableClientActorContractState) contiguousSettlementHighWaterWith(newWorkID string) uint64 {
	high := s.SettlementHighWater
	for {
		next := high + 1
		workID, ok := s.WorkBySequence[next]
		if !ok {
			return high
		}
		if workID == newWorkID {
			high = next
			continue
		}
		if _, settled := s.Settlements[workID]; !settled {
			return high
		}
		high = next
	}
}

func (s *DurableClientActorContractState) nextWorkSequence() uint64 {
	if s.NextSequence == 0 {
		s.NextSequence = 1
	}
	sequence := s.NextSequence
	s.NextSequence++
	return sequence
}

func (s *DurableClientActorContractState) nextReplayLogSequence() uint64 {
	if s.NextReplaySequence == 0 {
		s.NextReplaySequence = 1
	}
	sequence := s.NextReplaySequence
	s.NextReplaySequence++
	return sequence
}

func (s *DurableClientActorContractState) ensureReady() error {
	if validateClientActorDurableID(s.ActorID) != nil || !validClientActorFence(s.CurrentFence) {
		return ErrClientActorCorruptState
	}
	s.ensureMaps()
	return nil
}

func (s *DurableClientActorContractState) RebuildIndexesFromLog() error {
	if validateClientActorDurableID(s.ActorID) != nil || !validClientActorFence(s.CurrentFence) {
		return ErrClientActorCorruptState
	}
	s.UserTurnByNonce = map[string]DurableClientActorNonceRecord{}
	s.WorkFamilies = map[string]ClientActorSemanticFamily{}
	s.WorkSequences = map[string]uint64{}
	s.WorkBySequence = map[uint64]string{}
	s.WorkThreads = map[string]string{}
	maxWorkSequence := uint64(0)
	maxReplaySequence := uint64(0)
	for _, entry := range s.Log {
		if entry.ReplaySequence == 0 || entry.ReplaySequence <= maxReplaySequence {
			return ErrClientActorCorruptState
		}
		maxReplaySequence = entry.ReplaySequence
		switch entry.EntryKind {
		case ClientActorLogEntryKindWork:
			if entry.Sequence == 0 || !validClientActorFamily(entry.Family) || validateClientActorDurableID(entry.WorkID) != nil || validateClientActorDurableID(entry.ThreadID) != nil {
				return ErrClientActorCorruptState
			}
			if entry.Nonce != "" {
				if entry.Family != ClientActorSemanticUserTurn || validateClientActorDurableID(entry.Nonce) != nil {
					return ErrClientActorCorruptState
				}
			}
			if existingNonce, ok := s.UserTurnByNonce[entry.Nonce]; entry.Nonce != "" && ok {
				if existingNonce.WorkID != entry.WorkID || existingNonce.Digest != entry.Content.Digest {
					return ErrClientActorCorruptState
				}
			}
			if _, ok := s.WorkFamilies[entry.WorkID]; ok {
				if s.WorkFamilies[entry.WorkID] == entry.Family && s.WorkSequences[entry.WorkID] == entry.Sequence && s.WorkThreads[entry.WorkID] == entry.ThreadID && s.logEntryDigest(entry.WorkID) == entry.Content.Digest {
					continue
				}
				return ErrClientActorCorruptState
			}
			if _, ok := s.WorkBySequence[entry.Sequence]; ok {
				return ErrClientActorCorruptState
			}
			s.WorkFamilies[entry.WorkID] = entry.Family
			s.WorkSequences[entry.WorkID] = entry.Sequence
			s.WorkBySequence[entry.Sequence] = entry.WorkID
			s.WorkThreads[entry.WorkID] = entry.ThreadID
			if entry.Nonce != "" {
				s.UserTurnByNonce[entry.Nonce] = DurableClientActorNonceRecord{WorkID: entry.WorkID, Digest: entry.Content.Digest}
			}
			if entry.Sequence > maxWorkSequence {
				maxWorkSequence = entry.Sequence
			}
		case ClientActorLogEntryKindSettlement:
			if entry.Sequence != 0 || validateClientActorDurableID(entry.SourceWorkID) != nil || !validClientActorSettlementReplayID(entry.WorkID, entry.SourceWorkID) {
				return ErrClientActorCorruptState
			}
			if _, ok := s.WorkFamilies[entry.SourceWorkID]; !ok {
				return ErrClientActorCorruptState
			}
		default:
			return ErrClientActorCorruptState
		}
	}
	s.NextSequence = maxWorkSequence + 1
	s.NextReplaySequence = maxReplaySequence + 1
	s.ensureMaps()
	return nil
}

func (s *DurableClientActorContractState) ensureMaps() {
	if s.UserTurnByNonce == nil {
		s.UserTurnByNonce = map[string]DurableClientActorNonceRecord{}
	}
	if s.WorkFamilies == nil {
		s.WorkFamilies = map[string]ClientActorSemanticFamily{}
	}
	if s.WorkSequences == nil {
		s.WorkSequences = map[string]uint64{}
	}
	if s.WorkBySequence == nil {
		s.WorkBySequence = map[uint64]string{}
	}
	if s.WorkThreads == nil {
		s.WorkThreads = map[string]string{}
	}
	if s.WorkLeases == nil {
		s.WorkLeases = map[string]DurableClientActorLeaseAssignment{}
	}
	if s.Settlements == nil {
		s.Settlements = map[string]DurableClientActorSettlement{}
	}
	if s.Introspected == nil {
		s.Introspected = map[string]uint64{}
	}
	if s.IntrospectionSources == nil {
		s.IntrospectionSources = map[string]string{}
	}
	if s.PendingPresentation == nil {
		s.PendingPresentation = map[uint64]DurableClientActorPresentationTuple{}
	}
	if s.ContinuationKeys == nil {
		s.ContinuationKeys = map[string]DurableClientActorContinuationRecord{}
	}
}

func (s DurableClientActorContractState) logEntry(workID string) (DurableClientActorLogEntry, error) {
	for _, entry := range s.Log {
		if entry.WorkID == workID {
			return entry, nil
		}
	}
	return DurableClientActorLogEntry{}, ErrClientActorCorruptState
}

func (s DurableClientActorContractState) logEntryDigest(workID string) [32]byte {
	entry, err := s.logEntry(workID)
	if err != nil {
		return [32]byte{}
	}
	return entry.Content.Digest
}

func sameClientActorFence(a, b ClientActorExecutorFence) bool {
	return a.ActorEpoch == b.ActorEpoch && a.ExecutorGeneration == b.ExecutorGeneration && a.LeaseID != "" && a.LeaseID == b.LeaseID
}

func validClientActorFence(f ClientActorExecutorFence) bool {
	return f.ActorEpoch != 0 && f.ExecutorGeneration != 0 && validateClientActorDurableID(f.LeaseID) == nil
}

func validateClientActorDurableID(id string) error {
	if id == "" || len(id) > 128 {
		return ErrClientActorInvalidIdentifier
	}
	if rejectClientActorPrivateMaterial([]byte(id)) != nil || strings.HasPrefix(id, "settlement:") {
		return ErrClientActorInvalidIdentifier
	}
	for _, r := range id {
		if r <= 0x20 || r == 0x7f || r == '/' || r == '\\' {
			return ErrClientActorInvalidIdentifier
		}
	}
	return nil
}

func validClientActorSettlementReplayID(id, sourceWorkID string) bool {
	if sourceWorkID == "" || validateClientActorDurableID(sourceWorkID) != nil {
		return false
	}
	if id != "settlement:"+sourceWorkID {
		return false
	}
	if len(id) > len("settlement:")+128 {
		return false
	}
	if rejectClientActorPrivateMaterial([]byte(id)) != nil {
		return false
	}
	for _, r := range id {
		if r <= 0x20 || r == 0x7f || r == '/' || r == '\\' {
			return false
		}
	}
	return true
}

func validClientActorFamily(family ClientActorSemanticFamily) bool {
	switch family {
	case ClientActorSemanticTell, ClientActorSemanticAsk, ClientActorSemanticUserTurn, ClientActorSemanticSelfContinuation, ClientActorSemanticWaiting, ClientActorSemanticBlocked, ClientActorSemanticCompletion, ClientActorSemanticPresentationAck, ClientActorSemanticIntrospection:
		return true
	default:
		return false
	}
}

func durableClientActorContent(payload []byte) DurableClientActorContent {
	return DurableClientActorContent{Digest: sha256.Sum256(payload), Size: len(payload), Redacted: true}
}

func ClientActorSettlementDigestFromJSON(raw []byte) ([32]byte, error) {
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return [32]byte{}, err
	}
	canonical, err := json.Marshal(v)
	if err != nil {
		return [32]byte{}, err
	}
	return sha256.Sum256(canonical), nil
}

func rejectClientActorPrivateMaterial(payload []byte) error {
	lower := strings.ToLower(string(payload))
	canaries := []string{
		"raw_reasoning",
		"chain_of_thought",
		"session_credential",
		"credential_secret",
		"api_key",
		"openai_api_key",
		"authorization:",
		"authorization :",
		"bearer ",
		"-----begin private key-----",
		"-----begin rsa private key-----",
		"-----begin openSSH private key-----",
		"/home/",
		"/users/",
		".ssh/",
		".config/",
		"redacted",
	}
	for _, canary := range canaries {
		if strings.Contains(lower, strings.ToLower(canary)) {
			return ErrClientActorPrivacyCanary
		}
	}
	return nil
}
