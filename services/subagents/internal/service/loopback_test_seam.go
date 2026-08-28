package service

import "sync"

var loopbackServices sync.Map // map[string]*Service

func registerLoopbackService(id string, s *Service) { loopbackServices.Store(id, s) }
func lookupLoopbackService(id string) *Service {
	if v, ok := loopbackServices.Load(id); ok {
		return v.(*Service)
	}
	return nil
}
