package job

import (
	"x-ui/logger"
	"x-ui/config"
	"x-ui/web/service"
)

type UpdateCheckerJob struct {
	update_service service.ServerService
}

func NewUpdateCheckerJob() *UpdateCheckerJob {
	return new(UpdateCheckerJob)
}

func (j *UpdateCheckerJob) Run() {
	_, _, err := j.update_service.CheckForUpdate("AghayeCoder", "tx-ui", config.GetVersion())
	if err != nil {
		logger.Error("Error checking for update: ", err)
	}
}
