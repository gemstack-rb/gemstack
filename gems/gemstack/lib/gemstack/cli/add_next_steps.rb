# frozen_string_literal: true

module GemStack
  module AddNextSteps
    STEPS = {
      "realtime" => "Next: declare channels in config/channels.rb, then GemStack.broadcast(...) — see docs/realtime.md",
      "auth" => "Next: gemstack db:migrate · open http://localhost:3000/signup · " \
                "`before :require_login` in controllers — see docs/authentication.md",
      "storage" => "Next: uploadFile(file) from frontend/lib/upload.ts · production: STORAGE_SERVICE=s3, S3_BUCKET " \
                   "— see docs/storage.md"
    }.freeze
  end
end
