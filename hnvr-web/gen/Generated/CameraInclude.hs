-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
module Generated.CameraInclude where
import Generated.ActualTypes
import IHP.ModelSupport (Include, GetModelById)

type instance Include "ptzHomePresetId" (Camera' ptzHomePresetId) = Camera' (GetModelById ptzHomePresetId)
