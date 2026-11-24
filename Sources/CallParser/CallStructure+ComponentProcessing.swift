// Component classification and processing for compound call signs.

extension CallStructure {
  /// Determine the type of this CallStructure from the call sign components.
  /// - Parameters:
  ///   - firstComponent: first component of the call sign.
  ///   - secondComponent: second component of the call sign.
  mutating func processComponents(firstComponent: String, secondComponent: String) {

    var componentTypes =
    (firstComponentType: getComponentType(candidate: firstComponent, position: 1),
     secondComponentType: getComponentType(candidate: secondComponent, position: 2))

    if componentTypes.firstComponentType == ComponentType.unknown ||
        componentTypes.secondComponentType == ComponentType.unknown {

      componentTypes = resolveAmbiguities(
        firstComponentType: componentTypes.firstComponentType,
        secondComponentType: componentTypes.secondComponentType
      )
    }

    baseCall = firstComponent
    prefix = secondComponent

    guard componentTypes.firstComponentType != .invalid,
          componentTypes.secondComponentType != .invalid else {
      return
    }

    if componentTypes.firstComponentType == .callSign {
      processCallFirst(firstComponent, secondComponent, secondType: componentTypes.secondComponentType)
    } else {
      processOtherFirst(firstComponent, secondComponent, types: componentTypes)
    }
  }

  private mutating func processCallFirst(_ first: String, _ second: String, secondType: ComponentType) {
    switch secondType {
    case .prefix:
      callStructureType = .callPrefix
    case .callSign:
      if second.prefix(1) == "B" {
        callStructureType = .callPrefix
        setCallSignFlags(firstComponent: first, secondComponent: "")
      } else if first.prefix(3) == "VU4" || first.prefix(3) == "VU7" {
        callStructureType = .callPrefix
        setCallSignFlags(firstComponent: second, secondComponent: "")
      }
    case .text:
      callStructureType = .callText
      setCallSignFlags(firstComponent: second, secondComponent: "")
    case .numeric:
      callStructureType = .callDigit
      setCallSignFlags(firstComponent: second, secondComponent: "")
    case .portable:
      callStructureType = .callPortable
      setCallSignFlags(firstComponent: second, secondComponent: "")
    default:
      return
    }
  }

  private mutating func processOtherFirst(
    _ first: String,
    _ second: String,
    types: (ComponentType, ComponentType)
  ) {
    switch types {
    case (.prefix, .callSign):
      callStructureType = .prefixCall
      setCallSignFlags(firstComponent: first, secondComponent: "")
      baseCall = second
      prefix = first
    case (.prefix, .portable):
      callStructureType = .invalid
    case (.text, .callSign):
      callStructureType = .callText
      baseCall = second
      prefix = first
      setCallSignFlags(firstComponent: second, secondComponent: "")
    case (.prefix, .unknown):
      callStructureType = .prefixCall
      baseCall = second
      prefix = first
    default:
      return
    }
  }

  /// Determine the type of CallStructure from the call sign components.
  /// - Parameters:
  ///   - firstComponent: first component of the call sign.
  ///   - secondComponent: second component of the call sign.
  ///   - thirdComponent: third component of the call sign.
  mutating func processComponents(firstComponent: String, secondComponent: String, thirdComponent: String) {

    var componentTypes =
    (firstComponentType: getComponentType(candidate: firstComponent, position: 1),
     secondComponentType: getComponentType(candidate: secondComponent, position: 2))

    let thirdComponentType = getComponentType(candidate: thirdComponent, position: 3)

    if componentTypes.firstComponentType == ComponentType.unknown ||
        componentTypes.secondComponentType == ComponentType.unknown {

      componentTypes = resolveAmbiguities(
        firstComponentType: componentTypes.firstComponentType,
        secondComponentType: componentTypes.secondComponentType
      )
    }

    baseCall = firstComponent
    prefix = secondComponent
    suffix1 = thirdComponent

    let types = (componentTypes.secondComponentType, thirdComponentType)
    switch componentTypes.firstComponentType {
    case .callSign:
      processThreeComponentsCallFirst(firstComponent, secondComponent, thirdComponent, types: types)
    case .prefix where componentTypes.secondComponentType == .callSign:
      processThreeComponentsPrefixFirst(firstComponent, secondComponent, thirdComponent, thirdType: thirdComponentType)
    default:
      return
    }
  }

  private mutating func processThreeComponentsCallFirst(
    _ first: String, _ second: String, _ third: String,
    types: (ComponentType, ComponentType)
  ) {
    switch types {
    case (.numeric, .portable):
      callStructureType = .callDigitPortable
      setCallSignFlags(firstComponent: third, secondComponent: "")
    case (.numeric, .text):
      callStructureType = .callDigitText
      setCallSignFlags(firstComponent: third, secondComponent: "")
    case (.portable, .portable):
      callStructureType = .callPortablePortable
      setCallSignFlags(firstComponent: second, secondComponent: "")
    case (.portable, .prefix):
      baseCall = first
      prefix = third
      suffix1 = second
      callStructureType = .callPortablePrefix
      setCallSignFlags(firstComponent: second, secondComponent: "")
    case (.portable, .text):
      callStructureType = .callPortableText
      setCallSignFlags(firstComponent: second, secondComponent: "")
    case (.prefix, .portable):
      callStructureType = .callPrefixPortable
      setCallSignFlags(firstComponent: third, secondComponent: "")
    case (.portable, .numeric):
      baseCall = first
      prefix = third
      suffix1 = second
      setCallSignFlags(firstComponent: third, secondComponent: "")
      callStructureType = .callDigitPortable
    default:
      return
    }
  }

  private mutating func processThreeComponentsPrefixFirst(
    _ first: String, _ second: String, _ third: String, thirdType: ComponentType
  ) {
    switch thirdType {
    case .portable:
      callStructureType = .prefixCallPortable
    case .text:
      callStructureType = .prefixCallText
    default:
      return
    }
    baseCall = second
    prefix = first
    suffix1 = third
  }

  /// Resolve the component types when one component is unknown.
  /// - Parameters:
  ///   - firstComponentType: firstComponentType description
  ///   - secondComponentType: secondComponentType description
  /// - Returns: ComponentType for each component
  func resolveAmbiguities(
    firstComponentType: ComponentType, secondComponentType: ComponentType
  ) -> (ComponentType, ComponentType) {

    var componentTypes = (componentType1: ComponentType.unknown, componentType2: ComponentType.unknown)

    switch true {
      // UU --> PC
    case firstComponentType == ComponentType.unknown && secondComponentType == ComponentType.unknown:
      componentTypes.componentType1 = ComponentType.prefix
      componentTypes.componentType2 = ComponentType.callSign

      // CU --> CP - I don't agree with this --> CT
    case firstComponentType == ComponentType.callSign && secondComponentType ==    ComponentType.unknown:
      componentTypes.componentType1 = ComponentType.callSign
      componentTypes.componentType2 = ComponentType.text

      // UC --> PC - I don't agree with this --> TC
    case firstComponentType == ComponentType.unknown && secondComponentType == ComponentType.callSign:
      componentTypes.componentType1 = ComponentType.prefix
      componentTypes.componentType2 = ComponentType.callSign

      // UP --> CP
    case firstComponentType == ComponentType.unknown && secondComponentType == ComponentType.prefix:
      componentTypes.componentType1 = ComponentType.callSign
      componentTypes.componentType2 = ComponentType.prefix

      // PU --> PC
    case firstComponentType == ComponentType.prefix && secondComponentType == ComponentType.unknown:
      componentTypes.componentType1 = ComponentType.prefix
      componentTypes.componentType2 = ComponentType.callSign

      // U --> C
    case firstComponentType == ComponentType.unknown:
      componentTypes.componentType1 = ComponentType.callSign
      componentTypes.componentType2 = secondComponentType

      // U --> C
    case secondComponentType == ComponentType.unknown:
      componentTypes.componentType1 = firstComponentType
      componentTypes.componentType2 = ComponentType.callSign

    default:
      componentTypes.componentType1 = ComponentType.unknown
      componentTypes.componentType2 = ComponentType.unknown
    }

    return componentTypes
  }

}
