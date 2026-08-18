-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
module Generated.PtzPresetInclude where
import Generated.ActualTypes
import IHP.ModelSupport (Include, GetModelById)

type instance Include "cameras" (PtzPreset' cameras) = PtzPreset' [Camera]
